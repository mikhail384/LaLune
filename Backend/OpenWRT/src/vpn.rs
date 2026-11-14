// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// OpenWRT VPN runtime. The backend owns a dedicated TUN (lalune0). Router and
// LAN traffic are selected with iptables marks and policy-routed into that TUN;
// the core process itself runs under a dedicated UID and always stays on the
// physical/main route, preventing a VPN recursion loop.

use anyhow::{bail, Context, Result};
use parking_lot::Mutex;
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
#[cfg(target_has_atomic = "64")]
use std::sync::atomic::AtomicU64;
#[cfg(not(target_has_atomic = "64"))]
use portable_atomic::AtomicU64;
use std::sync::Arc;
use std::time::Instant;

use crate::events::{Event, EventBus};

pub const CORE_LISTEN_PORT: u16 = 52230;
pub const TUN_NAME: &str = "lalune0";
pub const TUN_MTU: u16 = 1300;
pub const DEFAULT_TUN_IP: &str = "10.66.67.12";
pub const DEFAULT_DNS: &str = "8.8.8.8,8.8.4.4";

const ROUTE_TABLE: &str = "10620";
const UID_RULE_PRIORITY: &str = "10620";
const MARK_RULE_PRIORITY: &str = "10622";
const VPN_MARK: &str = "0x1062/0xffff";
const OUTPUT_CHAIN: &str = "LALUNE_OUTPUT";
const PREROUTING_CHAIN: &str = "LALUNE_PREROUTING";
const NAT_CHAIN: &str = "LALUNE_NAT";

const LOCAL_DESTINATIONS: &[&str] = &[
    "0.0.0.0/8",
    "10.0.0.0/8",
    "100.64.0.0/10",
    "127.0.0.0/8",
    "169.254.0.0/16",
    "172.16.0.0/12",
    "192.168.0.0/16",
    "224.0.0.0/4",
    "240.0.0.0/4",
];

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VpnStatus {
    pub state: String,
    pub connected: bool,
    pub uptime_sec: u64,
    pub config_id: i64,
    pub message: String,
    pub since: String,
}

impl Default for VpnStatus {
    fn default() -> Self {
        Self {
            state: "disconnected".into(),
            connected: false,
            uptime_sec: 0,
            config_id: 0,
            message: String::new(),
            since: String::new(),
        }
    }
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VpnStats {
    pub rx_bytes: u64,
    pub tx_bytes: u64,
    pub rx_rate: u64,
    pub tx_rate: u64,
    pub active_sessions: i32,
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TunConf {
    pub ip: String,
    pub dns: String,
    pub mtu: u16,
}

pub struct VpnRuntime {
    pub running: Arc<AtomicBool>,
    pub connecting: AtomicBool,
    pub rx_bytes: Arc<AtomicU64>,
    pub tx_bytes: Arc<AtomicU64>,
    pub started_at: Arc<Mutex<Option<Instant>>>,
    pub tun_conf: Arc<Mutex<Option<TunConf>>>,
    pub handle: Mutex<Option<crate::linux_tun::Session>>,
    routing: Mutex<Option<OpenWrtRouting>>,
    pub core_uid: AtomicU32,
    pub operation: tokio::sync::Mutex<()>,
    pub watchdog: Mutex<Option<tokio::task::JoinHandle<()>>>,
}

impl VpnRuntime {
    pub fn new() -> Self {
        Self {
            running: Arc::new(AtomicBool::new(false)),
            connecting: AtomicBool::new(false),
            rx_bytes: Arc::new(AtomicU64::new(0)),
            tx_bytes: Arc::new(AtomicU64::new(0)),
            started_at: Arc::new(Mutex::new(None)),
            tun_conf: Arc::new(Mutex::new(None)),
            handle: Mutex::new(None),
            routing: Mutex::new(None),
            core_uid: AtomicU32::new(0),
            operation: tokio::sync::Mutex::new(()),
            watchdog: Mutex::new(None),
        }
    }

    pub fn status(&self, config_id: i64) -> VpnStatus {
        let running = self.running.load(Ordering::Relaxed);
        let started_at = *self.started_at.lock();
        let uptime = started_at.map(|t| t.elapsed().as_secs()).unwrap_or(0);
        let since = started_at.map(|_| chrono::Utc::now().to_rfc3339()).unwrap_or_default();

        VpnStatus {
            state: if running { "connected".into() } else { "disconnected".into() },
            connected: running,
            uptime_sec: uptime,
            config_id,
            message: String::new(),
            since,
        }
    }

    pub fn stats(&self) -> VpnStats {
        VpnStats {
            rx_bytes: self.rx_bytes.load(Ordering::Relaxed),
            tx_bytes: self.tx_bytes.load(Ordering::Relaxed),
            rx_rate: 0,
            tx_rate: 0,
            active_sessions: if self.running.load(Ordering::Relaxed) { 1 } else { 0 },
        }
    }

    pub async fn stop(&self) {
        let watchdog = { self.watchdog.lock().take() };
        if let Some(task) = watchdog { task.abort(); let _ = task.await; }
        self.stop_tun().await;
    }

    pub async fn stop_tun(&self) {
        self.running.store(false, Ordering::Release);
        // Remove policy routing/iptables first so no new packet is sent to a
        // TUN that is about to disappear.
        let routing = { self.routing.lock().take() };
        drop(routing);
        let session = { self.handle.lock().take() };
        if let Some(session) = session { session.stop().await; }
        *self.started_at.lock() = None;
        *self.tun_conf.lock() = None;
    }
}

pub fn start_tun(runtime: Arc<VpnRuntime>, tun_ip: String, tun_dns: String, events: EventBus) -> Result<()> {
    let uid = runtime.core_uid.load(Ordering::Acquire);
    if uid == 0 {
        bail!("Не определён UID ядра; безопасная маршрутизация OpenWRT невозможна");
    }

    // linux_tun only creates the fd/interface and UDP bridge here. OpenWRT
    // installs its own iptables + fwmark policy below instead of replacing the
    // system default route.
    let session = crate::linux_tun::Session::start(
        TUN_NAME,
        &tun_ip,
        &tun_dns,
        TUN_MTU,
        CORE_LISTEN_PORT,
        uid,
        runtime.running.clone(),
        runtime.rx_bytes.clone(),
        runtime.tx_bytes.clone(),
        events.clone(),
        false,
        Vec::new(),
    )?;

    let routing = match OpenWrtRouting::install(TUN_NAME, &tun_dns, uid, events.clone()) {
        Ok(routing) => routing,
        Err(error) => {
            drop(session);
            runtime.running.store(false, Ordering::Release);
            return Err(error).context("Настройка OpenWRT iptables/policy routing");
        }
    };

    *runtime.routing.lock() = Some(routing);
    *runtime.handle.lock() = Some(session);
    *runtime.started_at.lock() = Some(Instant::now());
    *runtime.tun_conf.lock() = Some(TunConf { ip: tun_ip.clone(), dns: tun_dns.clone(), mtu: TUN_MTU });
    events.emit(Event::named("tun_ready", serde_json::json!({
        "ip": tun_ip,
        "dns": tun_dns,
        "mtu": TUN_MTU,
        "interface": TUN_NAME,
        "routing": "iptables-fwmark",
        "mark": VPN_MARK,
        "table": ROUTE_TABLE,
    })));
    events.emit(Event::log(format!(
        "[TUN] {} ready; iptables mark={} -> table={} -> {}",
        TUN_NAME, VPN_MARK, ROUTE_TABLE, TUN_NAME
    )));
    Ok(())
}

struct OpenWrtRouting {
    name: String,
    uid: u32,
    dns: Option<(PathBuf, Vec<u8>, Vec<u8>)>,
    output_chain: bool,
    prerouting_chain: bool,
    nat_chain: bool,
    output_jump: bool,
    prerouting_jump: bool,
    nat_jump: bool,
    forward_out: bool,
    forward_in: bool,
    fw4_handles: Vec<u64>,
    uid_rule: bool,
    mark_rule: bool,
    route: bool,
    nat: NatMode,
    /// iptables NAT chain is actually populated (MASQUERADE or SNAT).
    nat_chain_used: bool,
    /// Native nftables table `ip lalune_nat` was created.
    nft_nat: bool,
    /// Packet marking done by nftables table `ip lalune_mangle` (router without iptables).
    nft_mangle: bool,
    events: EventBus,
}

/// Which NAT implementation worked on this router.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum NatMode {
    IptMasquerade,
    Nft,
    IptSnat,
    /// No NAT implementation was available.
    None,
}

const NFT_NAT_TABLE: &str = "lalune_nat";
const NFT_MANGLE_TABLE: &str = "lalune_mangle";

/// Tries available NAT implementations; callers must reject a missing NAT
/// before activating packet selection for LAN clients.
fn install_nat(name: &str, iptables_nat: bool, events: &EventBus) -> NatMode {
    // 1. classic iptables MASQUERADE (needs xt_MASQUERADE / kmod-ipt-nat)
    if iptables_nat {
        match iptables(&["-t", "nat", "-A", NAT_CHAIN, "-j", "MASQUERADE"]) {
            Ok(_) => return NatMode::IptMasquerade,
            Err(error) => events.emit(Event::log(format!(
                "[ROUTE] iptables MASQUERADE unavailable ({}); trying nftables",
                first_line(&error.to_string())
            ))),
        }
    }

    // 2. native nftables masquerade (needs nft_masq / kmod-nft-nat)
    try_nft(&["delete", "table", "ip", NFT_NAT_TABLE]);
    let script = nft_masquerade_script(name);
    if run_nft_script(&script).is_ok() {
        events.emit(Event::log("[ROUTE] NAT via nftables masquerade"));
        return NatMode::Nft;
    }
    try_nft(&["delete", "table", "ip", NFT_NAT_TABLE]);

    // 3. fixed-address SNAT (xt_SNAT is sometimes present without MASQUERADE)
    if let Some(addr) = tun_ipv4(name).filter(|_| iptables_nat) {
        if iptables(&["-t", "nat", "-A", NAT_CHAIN, "-j", "SNAT", "--to-source", &addr]).is_ok() {
            events.emit(Event::log(format!("[ROUTE] NAT via iptables SNAT -> {addr}")));
            return NatMode::IptSnat;
        }
    }

    events.emit(Event::log(
        "[ROUTE] NAT недоступен (нет xt_MASQUERADE/nft_masq в ядре). \
         Установите kmod-ipt-nat и kmod-nft-nat (opkg/apk install) для полной работы",
    ));
    NatMode::None
}

fn first_line(text: &str) -> String {
    text.lines().next().unwrap_or("").chars().take(160).collect()
}

fn nft_masquerade_script(name: &str) -> String {
    format!(
        "table ip {NFT_NAT_TABLE} {{\n\
         \tchain postrouting {{\n\
         \t\ttype nat hook postrouting priority srcnat; policy accept;\n\
         \t\toifname \"{name}\" masquerade\n\
         \t}}\n\
         }}\n"
    )
}

fn run_nft_script(script: &str) -> Result<()> {
    use std::io::Write;
    let mut child = Command::new("nft")
        .args(["-f", "-"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .context("Не удалось запустить nft")?;
    child
        .stdin
        .take()
        .context("nft stdin")?
        .write_all(script.as_bytes())?;
    let output = child.wait_with_output()?;
    if !output.status.success() {
        bail!("nft: {}", String::from_utf8_lossy(&output.stderr).trim());
    }
    Ok(())
}

/// First IPv4 address of the TUN device (e.g. `10.66.67.2`).
fn tun_ipv4(name: &str) -> Option<String> {
    let out = ip(&["-4", "-o", "addr", "show", "dev", name]).ok()?;
    out.split_whitespace()
        .skip_while(|t| *t != "inet")
        .nth(1)
        .map(|cidr| cidr.split('/').next().unwrap_or(cidr).to_string())
}

impl OpenWrtRouting {
    fn install(name: &str, dns: &str, uid: u32, events: EventBus) -> Result<Self> {
        if unsafe { libc::geteuid() } != 0 {
            bail!("OpenWRT VPN требует root/CAP_NET_ADMIN");
        }
        require_program("ip")?;
        // Малые сборки OpenWrt 25.x (Keenetic и др.) идут без iptables-nft, но с nftables:
        // тогда разметку пакетов делаем средствами nft.
        // nft предпочтительнее и при наличии iptables: матч `skuid` исключает пакеты ядра из
        // разметки, а iptables `-m owner` (xt_owner) на малых прошивках часто отсутствует.
        let nft_ok = Command::new("nft").args(["list", "tables"]).output().is_ok_and(|o| o.status.success());
        let use_nft = nft_ok || iptables_program().is_none();
        if use_nft && !nft_ok {
            bail!("Не найдены ни iptables, ни работающий nft");
        }
        try_nft(&["delete", "table", "ip", NFT_MANGLE_TABLE]);

        cleanup_legacy_policy(&events);
        cleanup_stale_chains(name, &events);
        ensure_route_slots_free()?;
        let wan = physical_default_dev()?;

        let mut routing = Self {
            name: name.into(), uid, dns: None,
            output_chain: false, prerouting_chain: false, nat_chain: false,
            output_jump: false, prerouting_jump: false, nat_jump: false,
            forward_out: false, forward_in: false, fw4_handles: Vec::new(),
            uid_rule: false, mark_rule: false, route: false,
            nat: NatMode::None, nat_chain_used: false, nft_nat: false, nft_mangle: false,
            events,
        };
        if use_nft {
            routing.install_nft(name, &wan, uid, dns)?;
            return Ok(routing);
        }

        routing.create_chain("mangle", OUTPUT_CHAIN)?;
        routing.output_chain = true;
        routing.create_chain("mangle", PREROUTING_CHAIN)?;
        routing.prerouting_chain = true;
        // The iptables nat table may be missing entirely on stripped kernels;
        // that only disables LAN NAT (see install_nat), not the whole VPN.
        routing.nat_chain = routing.create_chain("nat", NAT_CHAIN).is_ok();

        // Пакеты самого ядра не помечаем вовсе. Одного правила `ip rule uidrange` мало: после
        // смены метки в mangle/OUTPUT ядро заново ищет маршрут и (на ряде ядер) теряет UID сокета,
        // из-за чего трафик ядра к TURN/серверу уходил обратно в TUN и зацикливался.
        let uid_text = uid.to_string();
        if let Err(error) = iptables(&[
            "-t", "mangle", "-A", OUTPUT_CHAIN,
            "-m", "owner", "--uid-owner", &uid_text, "-j", "RETURN",
        ]) {
            routing.events.emit(Event::log(format!(
                "[ROUTE] WARNING: iptables owner match unavailable ({}); install iptables-mod-extra/kmod-ipt-extra",
                first_line(&error.to_string())
            )));
        }
        for destination in LOCAL_DESTINATIONS {
            iptables(&["-t", "mangle", "-A", OUTPUT_CHAIN, "-d", *destination, "-j", "RETURN"])?;
        }
        iptables(&[
            "-t", "mangle", "-A", OUTPUT_CHAIN,
            "-j", "MARK", "--set-xmark", VPN_MARK,
        ])?;

        iptables(&["-t", "mangle", "-A", PREROUTING_CHAIN, "-i", name, "-j", "RETURN"])?;
        iptables(&["-t", "mangle", "-A", PREROUTING_CHAIN, "-i", &wan, "-j", "RETURN"])?;
        for destination in LOCAL_DESTINATIONS {
            iptables(&["-t", "mangle", "-A", PREROUTING_CHAIN, "-d", *destination, "-j", "RETURN"])?;
        }
        iptables(&[
            "-t", "mangle", "-A", PREROUTING_CHAIN,
            "-j", "MARK", "--set-xmark", VPN_MARK,
        ])?;
        // NAT for forwarded LAN traffic. The kernel of small ramips builds often
        // lacks xt_MASQUERADE ("Extension MASQUERADE revision 0 not supported"),
        // so try several implementations instead of failing the whole connect.
        routing.nat = install_nat(name, routing.nat_chain, &routing.events);
        routing.nat_chain_used = matches!(routing.nat, NatMode::IptMasquerade | NatMode::IptSnat);
        routing.nft_nat = matches!(routing.nat, NatMode::Nft);
        require_nat(routing.nat)?;

        // Table 10620 contains only the VPN default. The core UID has a higher
        // priority rule to main, so its transport can never recurse into lalune0.
        ip(&["-4", "route", "add", "default", "dev", name, "table", ROUTE_TABLE])?;
        routing.route = true;
        let uidrange = format!("{uid}-{uid}");
        ip(&[
            "-4", "rule", "add", "priority", UID_RULE_PRIORITY,
            "uidrange", &uidrange, "lookup", "main",
        ])?;
        routing.uid_rule = true;
        ip(&[
            "-4", "rule", "add", "priority", MARK_RULE_PRIORITY,
            "fwmark", VPN_MARK, "lookup", ROUTE_TABLE,
        ])?;
        routing.mark_rule = true;

        // Activate packet selection only after the policy table is ready.
        iptables(&["-t", "mangle", "-A", "OUTPUT", "-j", OUTPUT_CHAIN])?;
        routing.output_jump = true;
        iptables(&["-t", "mangle", "-A", "PREROUTING", "-j", PREROUTING_CHAIN])?;
        routing.prerouting_jump = true;
        if routing.nat_chain_used {
            iptables(&["-t", "nat", "-A", "POSTROUTING", "-o", name, "-j", NAT_CHAIN])?;
            routing.nat_jump = true;
        }

        // Legacy firewall3/iptables path. On firewall4 we additionally insert
        // temporary accept rules into inet/fw4 below, because a separate nft
        // base chain can otherwise reject traffic to an unzoned TUN device.
        iptables(&["-t", "filter", "-I", "FORWARD", "1", "-o", name, "-j", "ACCEPT"])?;
        routing.forward_out = true;
        iptables(&["-t", "filter", "-I", "FORWARD", "1", "-i", name, "-j", "ACCEPT"])?;
        routing.forward_in = true;
        routing.fw4_handles = install_fw4_compat(name)?;

        routing.install_dns(dns)?;
        routing.events.emit(Event::log(format!(
            "[ROUTE] wan={wan}; core_uid={uid}; OUTPUT/PREROUTING -> mark {VPN_MARK}; NAT -> {name}"
        )));
        Ok(routing)
    }

    /// Вариант без iptables: mark + policy routing + NAT целиком на nftables.
    fn install_nft(&mut self, name: &str, wan: &str, uid: u32, dns: &str) -> Result<()> {
        let local = LOCAL_DESTINATIONS.join(", ");
        let set_mark = "meta mark set meta mark & 0xffff0000 | 0x1062";
        // MSS = MTU туннеля - 40 (IPv4 + TCP): иначе большие пакеты клиентов LAN теряются в туннеле
        // и соединения очень медленные.
        let mss = TUN_MTU - 40;
        let script = format!(
            "table ip {NFT_MANGLE_TABLE} {{\n\
             \tchain output {{\n\
             \t\ttype route hook output priority mangle; policy accept;\n\
             \t\tmeta skuid {uid} return\n\
             \t\tip daddr {{ {local} }} return\n\
             \t\t{set_mark}\n\
             \t}}\n\
             \tchain prerouting {{\n\
             \t\ttype filter hook prerouting priority mangle; policy accept;\n\
             \t\tiifname \"{name}\" return\n\
             \t\tiifname \"{wan}\" return\n\
             \t\tip daddr {{ {local} }} return\n\
             \t\t{set_mark}\n\
             \t}}\n\
             \tchain forward {{\n\
             \t\ttype filter hook forward priority mangle; policy accept;\n\
             \t\toifname \"{name}\" tcp flags & (syn | rst) == syn tcp option maxseg size > {mss} tcp option maxseg size set {mss}\n\
             \t\tiifname \"{name}\" tcp flags & (syn | rst) == syn tcp option maxseg size > {mss} tcp option maxseg size set {mss}\n\
             \t}}\n\
             }}\n"
        );
        // Сначала маршрутная таблица, потом правила разметки — как и в iptables-варианте.
        ip(&["-4", "route", "add", "default", "dev", name, "table", ROUTE_TABLE])?;
        self.route = true;
        let uidrange = format!("{uid}-{uid}");
        ip(&["-4", "rule", "add", "priority", UID_RULE_PRIORITY, "uidrange", &uidrange, "lookup", "main"])?;
        self.uid_rule = true;
        ip(&["-4", "rule", "add", "priority", MARK_RULE_PRIORITY, "fwmark", VPN_MARK, "lookup", ROUTE_TABLE])?;
        self.mark_rule = true;

        self.nat = install_nat(name, false, &self.events);
        self.nft_nat = matches!(self.nat, NatMode::Nft);
        require_nat(self.nat)?;

        self.nft_mangle = true; // даже при ошибке Drop удалит возможные остатки
        run_nft_script(&script).context("Не удалось создать nft-таблицу разметки LaLune")?;
        self.fw4_handles = install_fw4_compat(name)?;
        self.install_dns(dns)?;
        self.events.emit(Event::log(format!(
            "[ROUTE] nftables-режим (iptables не найден): wan={wan}; core_uid={uid}; mark {VPN_MARK}; NAT -> {name}"
        )));
        Ok(())
    }

    fn create_chain(&self, table: &str, chain: &str) -> Result<()> {
        iptables(&["-t", table, "-N", chain])
            .with_context(|| format!("Не удалось создать iptables chain {table}/{chain}"))
            .map(|_| ())
    }

    fn install_dns(&mut self, dns: &str) -> Result<()> {
        let installed = dns_content(dns)?;
        let path = PathBuf::from("/etc/resolv.conf");
        let previous = fs::read(&path).context("Чтение исходного /etc/resolv.conf")?;
        if let Err(error) = fs::write(&path, &installed) {
            let _ = fs::write(&path, &previous);
            return Err(error).context("Настройка DNS OpenWRT для VPN");
        }
        self.dns = Some((path, previous, installed));
        Ok(())
    }
}

impl Drop for OpenWrtRouting {
    fn drop(&mut self) {
        // Stop selecting packets first, then remove policy routes/chains.
        if self.output_jump {
            try_iptables(&["-t", "mangle", "-D", "OUTPUT", "-j", OUTPUT_CHAIN]);
        }
        if self.prerouting_jump {
            try_iptables(&["-t", "mangle", "-D", "PREROUTING", "-j", PREROUTING_CHAIN]);
        }
        if self.forward_in {
            try_iptables(&["-t", "filter", "-D", "FORWARD", "-i", &self.name, "-j", "ACCEPT"]);
        }
        if self.forward_out {
            try_iptables(&["-t", "filter", "-D", "FORWARD", "-o", &self.name, "-j", "ACCEPT"]);
        }
        for handle in self.fw4_handles.drain(..) {
            delete_fw4_handle(handle);
        }
        if self.nat_jump {
            try_iptables(&["-t", "nat", "-D", "POSTROUTING", "-o", &self.name, "-j", NAT_CHAIN]);
        }
        if self.mark_rule {
            try_ip(&["-4", "rule", "del", "priority", MARK_RULE_PRIORITY]);
        }
        if self.uid_rule {
            try_ip(&["-4", "rule", "del", "priority", UID_RULE_PRIORITY]);
        }
        if self.route {
            try_ip(&["-4", "route", "flush", "table", ROUTE_TABLE]);
        }
        if self.output_chain {
            try_iptables(&["-t", "mangle", "-F", OUTPUT_CHAIN]);
            try_iptables(&["-t", "mangle", "-X", OUTPUT_CHAIN]);
        }
        if self.prerouting_chain {
            try_iptables(&["-t", "mangle", "-F", PREROUTING_CHAIN]);
            try_iptables(&["-t", "mangle", "-X", PREROUTING_CHAIN]);
        }
        if self.nat_chain {
            try_iptables(&["-t", "nat", "-F", NAT_CHAIN]);
            try_iptables(&["-t", "nat", "-X", NAT_CHAIN]);
        }
        if self.nft_mangle {
            try_nft(&["delete", "table", "ip", NFT_MANGLE_TABLE]);
        }
        if self.nft_nat {
            try_nft(&["delete", "table", "ip", NFT_NAT_TABLE]);
        }
        if let Some((path, previous, installed)) = &self.dns {
            if fs::read(path).ok().as_deref() == Some(installed.as_slice()) {
                if let Err(error) = fs::write(path, previous) {
                    self.events.emit(Event::error(format!("Не удалось восстановить DNS: {error}")));
                }
            }
        }
        self.events.emit(Event::log(format!(
            "[ROUTE] iptables/policy routing removed (core_uid={})",
            self.uid
        )));
    }
}

/// `ip -N` (numeric) есть не во всех сборках iproute2 (на ip-tiny/busybox его может не быть):
/// пробуем с `-N`, иначе без него. Названия таблиц разбираются в вызывающем коде.
fn ip_numeric(args: &[&str]) -> Result<String> {
    let mut with_n = vec!["-N"];
    with_n.extend_from_slice(args);
    match ip(&with_n) {
        Ok(out) => Ok(out),
        Err(_) => ip(args),
    }
}

fn require_program(program: &str) -> Result<()> {
    let status = Command::new(program).arg("--version").output();
    if status.is_err() {
        bail!("Не найдена команда {program}; установщик OpenWRT должен поставить ip-full и iptables-nft");
    }
    Ok(())
}

fn run(program: &str, args: &[&str]) -> Result<String> {
    let output = Command::new(program)
        .args(args)
        .output()
        .with_context(|| format!("Не удалось запустить {program}"))?;
    if !output.status.success() {
        bail!(
            "{} {}: {}",
            program,
            args.join(" "),
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

fn ip(args: &[&str]) -> Result<String> { run("ip", args) }

fn iptables_program() -> Option<&'static str> {
    for program in ["iptables", "iptables-nft"] {
        if Command::new(program).arg("--version").output().is_ok() {
            return Some(program);
        }
    }
    None
}

fn require_iptables() -> Result<()> {
    if iptables_program().is_none() {
        bail!("Не найдены iptables/iptables-nft; установите пакет iptables-nft");
    }
    Ok(())
}

fn iptables(args: &[&str]) -> Result<String> {
    let program = iptables_program().context("Не найдены iptables/iptables-nft")?;
    run(program, args)
}

fn try_ip(args: &[&str]) { let _ = Command::new("ip").args(args).output(); }
fn try_iptables(args: &[&str]) {
    if let Some(program) = iptables_program() {
        let _ = Command::new(program).args(args).output();
    }
}

fn chain_exists(table: &str, chain: &str) -> bool {
    iptables_program().is_some_and(|program| {
        Command::new(program)
            .args(["-t", table, "-S", chain])
            .output()
            .is_ok_and(|output| output.status.success())
    })
}

fn try_nft(args: &[&str]) { let _ = Command::new("nft").args(args).output(); }

fn delete_fw4_handle(handle: u64) {
    let handle = handle.to_string();
    try_nft(&["delete", "rule", "inet", "fw4", "forward", "handle", &handle]);
}

fn fw4_forward_exists() -> bool {
    Command::new("nft")
        .args(["list", "chain", "inet", "fw4", "forward"])
        .output()
        .is_ok_and(|output| output.status.success())
}

fn fw4_handles_with_prefix(prefix: &str) -> Vec<u64> {
    let Ok(output) = Command::new("nft")
        .args(["-a", "list", "chain", "inet", "fw4", "forward"])
        .output() else { return Vec::new() };
    if !output.status.success() { return Vec::new(); }
    let text = String::from_utf8_lossy(&output.stdout);
    text.lines()
        .filter(|line| line.contains(prefix))
        .filter_map(|line| line.rsplit_once("handle ").and_then(|(_, handle)| handle.trim().parse().ok()))
        .collect()
}

fn install_fw4_compat(name: &str) -> Result<Vec<u64>> {
    if !fw4_forward_exists() { return Ok(Vec::new()); }

    // Remove rules left by a killed backend before creating the current set.
    for handle in fw4_handles_with_prefix("lalune-vpn-") {
        delete_fw4_handle(handle);
    }

    let rules: [(&str, Vec<&str>); 3] = [
        ("lalune-vpn-mark", vec!["meta", "mark", "&", "0xffff", "==", "0x1062", "accept"]),
        ("lalune-vpn-in", vec!["iifname", name, "accept"]),
        ("lalune-vpn-out", vec!["oifname", name, "accept"]),
    ];
    for (comment, expression) in rules {
        let mut args = vec!["insert", "rule", "inet", "fw4", "forward"];
        args.extend(expression);
        args.extend(["comment", comment]);
        if let Err(error) = run("nft", &args) {
            for handle in fw4_handles_with_prefix("lalune-vpn-") {
                delete_fw4_handle(handle);
            }
            return Err(error).with_context(|| format!("Не удалось разрешить {name} в firewall4"));
        }
    }

    let handles = fw4_handles_with_prefix("lalune-vpn-");
    if handles.len() != 3 {
        for handle in handles.iter().copied() {
            delete_fw4_handle(handle);
        }
        bail!("Не удалось подтвердить временные firewall4 rules для {name}");
    }
    Ok(handles)
}

fn cleanup_legacy_policy(events: &EventBus) {
    // Previous OpenWRT releases used linux_tun's three-rule full-tunnel setup:
    // 10620 uidrange -> main, 10621 main suppress default, 10622 -> table 10620.
    // A hard-killed backend could leave those rules behind after csqtt0 vanished.
    let Ok(rules) = ip_numeric(&["-4", "rule", "show"]) else { return };
    let uses_main = |line: &str| line.split_whitespace().collect::<Vec<_>>().windows(2)
        .any(|pair| pair == ["lookup", "254"] || pair == ["lookup", "main"]);
    let legacy = rules.lines().any(|line| {
        line.trim_start().starts_with("10620:")
            && line.contains("uidrange ") && uses_main(line)
    }) && rules.lines().any(|line| {
        line.trim_start().starts_with("10621:")
            && uses_main(line)
            && line.contains("suppress_prefixlength 0")
    }) && rules.lines().any(|line| {
        line.trim_start().starts_with("10622:") && !line.contains("fwmark ")
            && line.split_whitespace().collect::<Vec<_>>().windows(2)
                .any(|pair| pair == ["lookup", ROUTE_TABLE])
    });
    if !legacy { return; }

    events.emit(Event::log("[ROUTE] removing legacy csqtt0 policy-routing state"));
    try_ip(&["-4", "rule", "del", "priority", "10622"]);
    try_ip(&["-4", "rule", "del", "priority", "10621"]);
    try_ip(&["-4", "rule", "del", "priority", "10620"]);
    try_ip(&["-4", "route", "flush", "table", ROUTE_TABLE]);
}

fn cleanup_stale_chains(name: &str, events: &EventBus) {
    let stale = chain_exists("mangle", OUTPUT_CHAIN)
        || chain_exists("mangle", PREROUTING_CHAIN)
        || chain_exists("nat", NAT_CHAIN);
    if !stale { return; }
    events.emit(Event::log("[ROUTE] removing stale LaLune iptables state"));
    for handle in fw4_handles_with_prefix("lalune-vpn-") {
        delete_fw4_handle(handle);
    }
    try_iptables(&["-t", "filter", "-D", "FORWARD", "-i", name, "-j", "ACCEPT"]);
    try_iptables(&["-t", "filter", "-D", "FORWARD", "-o", name, "-j", "ACCEPT"]);
    try_iptables(&["-t", "mangle", "-D", "OUTPUT", "-j", OUTPUT_CHAIN]);
    try_iptables(&["-t", "mangle", "-D", "PREROUTING", "-j", PREROUTING_CHAIN]);
    try_iptables(&["-t", "nat", "-D", "POSTROUTING", "-o", name, "-j", NAT_CHAIN]);
    for (table, chain) in [("mangle", OUTPUT_CHAIN), ("mangle", PREROUTING_CHAIN), ("nat", NAT_CHAIN)] {
        try_iptables(&["-t", table, "-F", chain]);
        try_iptables(&["-t", table, "-X", chain]);
    }
    // Do not remove policy rules by priority or flush a table here: their
    // ownership cannot be established from the existence of our chains.
    // ensure_route_slots_free reports collisions without touching them.
    try_nft(&["delete", "table", "ip", NFT_NAT_TABLE]);
}

fn require_nat(mode: NatMode) -> Result<()> {
    if matches!(mode, NatMode::None) {
        bail!("NAT недоступен: установите совместимые с ядром kmod-nft-nat или kmod-ipt-nat; маршрутизация не включена");
    }
    Ok(())
}

fn ensure_route_slots_free() -> Result<()> {
    let rules = ip_numeric(&["-4", "rule", "show"])?;
    for line in rules.lines() {
        let priority = line.split(':').next().map(str::trim).unwrap_or("");
        if priority == UID_RULE_PRIORITY || priority == MARK_RULE_PRIORITY || line.contains(&format!("lookup {ROUTE_TABLE}")) {
            bail!("Таблица/приоритет policy routing LaLune уже занят: {line}");
        }
    }
    // Querying a single, not-yet-created FIB table exits with an error.
    let routes = ip_numeric(&["-4", "route", "show", "table", "all"])?;
    if routes.lines().any(|line| line.split_whitespace().collect::<Vec<_>>()
        .windows(2).any(|pair| pair == ["table", ROUTE_TABLE])) {
        bail!("Таблица маршрутизации {ROUTE_TABLE} уже содержит маршруты");
    }
    Ok(())
}

fn physical_default_dev() -> Result<String> {
    let routes = ip(&["-4", "route", "show", "default"])?;
    for line in routes.lines() {
        let fields: Vec<&str> = line.split_whitespace().collect();
        if fields.first().copied() != Some("default") { continue; }
        if let Some(dev) = fields.windows(2).find(|pair| pair[0] == "dev").map(|pair| pair[1]) {
            return Ok(dev.to_string());
        }
    }
    bail!("Не найден физический IPv4 default route OpenWRT")
}

fn dns_content(dns: &str) -> Result<Vec<u8>> {
    let mut text = String::new();
    for address in dns.split(',').map(str::trim).filter(|s| !s.is_empty()) {
        let _: std::net::Ipv4Addr = address.parse().context("Некорректный IPv4 DNS")?;
        text.push_str(&format!("nameserver {address}\n"));
    }
    if text.is_empty() { bail!("Не указан DNS для TUN"); }
    Ok(text.into_bytes())
}

pub fn parse_tunconf(line: &str) -> Option<(String, String)> {
    if let Some(rest) = line.strip_prefix("TUNCONF:") {
        let parts: Vec<&str> = rest.splitn(2, ':').collect();
        if parts.len() == 2 {
            return Some((parts[0].trim().to_string(), parts[1].trim().to_string()));
        }
    }
    if line.contains("Tunnel IP:") && line.contains("DNS:") {
        let ip_idx = line.find("Tunnel IP:")?;
        let dns_idx = line.find("DNS:")?;
        if dns_idx > ip_idx {
            let ip_part = line[ip_idx + 10..dns_idx].trim().trim_end_matches('|').trim();
            let ip_clean = ip_part.split('/').next()?.trim().to_string();
            let dns_part = line[dns_idx + 4..].split('|').next()?.trim().to_string();
            if !ip_clean.is_empty() && !dns_part.is_empty() {
                return Some((ip_clean, dns_part));
            }
        }
    }
    None
}

pub fn parse_stats(line: &str) -> Option<(i32, f64)> {
    if !line.contains("Активных:") { return None; }
    let idx = line.find("Активных:")?;
    let after = &line[idx + "Активных:".len()..];
    let trimmed = after.trim_start();
    let end = trimmed.find(|c: char| !c.is_ascii_digit()).unwrap_or(trimmed.len());
    if end == 0 { return None; }
    let active: i32 = trimmed[..end].parse().ok()?;
    let traffic = line.find("Трафик:").and_then(|i| {
        let after = &line[i + "Трафик:".len()..];
        let t = after.trim_start();
        let end = t.find(|c: char| !c.is_ascii_digit() && c != '.').unwrap_or(t.len());
        t[..end].parse::<f64>().ok()
    }).unwrap_or(0.0);
    Some((active, traffic))
}

pub fn extract_ipv4_addrs(line: &str) -> Vec<String> {
    let mut result = Vec::new();
    let bytes = line.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if !bytes[i].is_ascii_digit() { i += 1; continue; }
        let start = i;
        let mut dots = 0;
        let mut last_was_digit = false;
        while i < bytes.len() {
            let c = bytes[i];
            if c.is_ascii_digit() { last_was_digit = true; i += 1; }
            else if c == b'.' && last_was_digit && dots < 3 { dots += 1; last_was_digit = false; i += 1; }
            else { break; }
        }
        if dots == 3 && last_was_digit {
            if let Ok(candidate) = std::str::from_utf8(&bytes[start..i]) {
                if candidate.parse::<std::net::Ipv4Addr>().is_ok() {
                    result.push(candidate.to_string());
                }
            }
        } else { i = start + 1; }
    }
    result
}

#[cfg(test)]
mod routing_tests {
    use super::*;

    #[test]
    fn missing_nat_is_a_startup_error() {
        assert!(require_nat(NatMode::None).is_err());
        for mode in [NatMode::IptMasquerade, NatMode::Nft, NatMode::IptSnat] {
            assert!(require_nat(mode).is_ok());
        }
    }

    fn isolated_network() {
        assert_eq!(unsafe { libc::geteuid() }, 0);
        assert_ne!(fs::read_link("/proc/self/ns/net").unwrap(), fs::read_link("/proc/1/ns/net").unwrap(),
            "Run routing tests in an isolated network namespace");
        ip(&["link", "set", "lo", "up"]).unwrap();
    }

    #[test]
    #[ignore = "requires root in an isolated Linux network namespace"]
    fn unused_policy_table_is_available() {
        isolated_network();
        ensure_route_slots_free().expect("A table without routes is available on first connection");
    }

    #[test]
    #[ignore = "requires root in an isolated Linux network namespace"]
    fn numeric_legacy_rules_are_removed() {
        isolated_network();
        ip(&["-4", "rule", "add", "priority", "10620", "uidrange", "61062-61062", "lookup", "main"]).unwrap();
        ip(&["-4", "rule", "add", "priority", "10621", "lookup", "main", "suppress_prefixlength", "0"]).unwrap();
        ip(&["-4", "rule", "add", "priority", "10622", "lookup", ROUTE_TABLE]).unwrap();
        ip(&["-4", "route", "add", "default", "dev", "lo", "table", ROUTE_TABLE]).unwrap();
        cleanup_legacy_policy(&EventBus::new(16));
        let rules = ip(&["-N", "-4", "rule", "show"]).unwrap();
        for priority in ["10620:", "10621:", "10622:"] {
            assert!(!rules.lines().any(|line| line.starts_with(priority)), "Legacy rule remains: {rules}");
        }
    }

    #[test]
    #[ignore = "requires root in an isolated Linux network namespace"]
    fn occupied_policy_table_is_preserved() {
        isolated_network();
        ip(&["-4", "route", "add", "198.51.100.0/24", "dev", "lo", "table", ROUTE_TABLE]).unwrap();
        assert!(ensure_route_slots_free().is_err());
        assert!(ip(&["-N", "-4", "route", "show", "table", ROUTE_TABLE]).unwrap().contains("198.51.100.0/24"));
    }

    #[test]
    #[ignore = "requires root in an isolated Linux network namespace"]
    fn unrelated_policy_rules_are_preserved() {
        isolated_network();
        ip(&["-4", "rule", "add", "priority", "10621", "lookup", "main", "suppress_prefixlength", "0"]).unwrap();
        ip(&["-4", "rule", "add", "priority", "10622", "fwmark", "0x123", "lookup", ROUTE_TABLE]).unwrap();
        let previous = ip(&["-N", "-4", "rule", "show"]).unwrap();
        cleanup_legacy_policy(&EventBus::new(16));
        assert_eq!(ip(&["-N", "-4", "rule", "show"]).unwrap(), previous);
    }
}
