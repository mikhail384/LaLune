// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// macOS: utun-интерфейс через крейт `tun` + маршруты через `route`,
// DNS через `networksetup`. Требует root (демон запускается через
// osascript "with administrator privileges" из приложения).
//
// ВНИМАНИЕ: код написан без доступа к Mac и не проходил ручную проверку —
// см. Backend/README.md, раздел macOS.
use anyhow::{bail, Context, Result};
use std::net::{Ipv4Addr, ToSocketAddrs};
use std::process::Command;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UdpSocket;
use tokio::task::JoinHandle;

use crate::events::{Event, EventBus};

fn run(program: &str, args: &[&str]) -> Result<String> {
    let output = Command::new(program)
        .args(args)
        .output()
        .with_context(|| format!("запуск {program}"))?;
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

/// (gateway, interface) физического default route.
fn physical_default_route() -> Result<(String, String)> {
    let text = run("route", &["-n", "get", "default"])?;
    let mut gateway = String::new();
    let mut iface = String::new();
    for line in text.lines() {
        let line = line.trim();
        if let Some(v) = line.strip_prefix("gateway:") {
            gateway = v.trim().to_string();
        } else if let Some(v) = line.strip_prefix("interface:") {
            iface = v.trim().to_string();
        }
    }
    if gateway.is_empty() {
        bail!("не найден физический IPv4 default gateway");
    }
    Ok((gateway, iface))
}

/// Резолвит "host:port"/"host" в IPv4 (адрес сервера ядра).
pub fn resolve_peer_ipv4(peer: &str) -> Option<Ipv4Addr> {
    let peer = peer.trim();
    if peer.is_empty() {
        return None;
    }
    if let Ok(ip) = peer.parse::<Ipv4Addr>() {
        return Some(ip);
    }
    let with_port = if peer.contains(':') { peer.to_string() } else { format!("{peer}:0") };
    with_port
        .to_socket_addrs()
        .ok()?
        .filter_map(|a| match a.ip() {
            std::net::IpAddr::V4(v4) => Some(v4),
            _ => None,
        })
        .next()
}

/// Удалённые IPv4-адреса процесса ядра (если он уже держит соединения).
fn core_remote_ips(pid: u32) -> Vec<String> {
    if pid == 0 {
        return Vec::new();
    }
    let out = Command::new("lsof")
        .args(["-nP", "-a", "-i4", "-p", &pid.to_string()])
        .output();
    let Ok(out) = out else { return Vec::new() };
    let text = String::from_utf8_lossy(&out.stdout);
    let mut ips = Vec::new();
    for token in text.split_whitespace() {
        if let Some((_, remote)) = token.split_once("->") {
            if let Some((ip, _)) = remote.rsplit_once(':') {
                if let Ok(addr) = ip.parse::<Ipv4Addr>() {
                    if !addr.is_loopback() && !ips.contains(&ip.to_string()) {
                        ips.push(ip.to_string());
                    }
                }
            }
        }
    }
    ips
}

fn network_services() -> Vec<String> {
    run("networksetup", &["-listallnetworkservices"])
        .map(|t| {
            t.lines()
                .skip(1) // первая строка — пояснение
                .filter(|l| !l.starts_with('*') && !l.trim().is_empty())
                .map(|l| l.trim().to_string())
                .collect()
        })
        .unwrap_or_default()
}

struct Routes {
    undo: Vec<Vec<String>>,
    /// (service, прежние DNS; пусто = были автоматические)
    dns: Vec<(String, Vec<String>)>,
    events: EventBus,
}

impl Routes {
    fn add(&mut self, args: &[&str]) -> Result<()> {
        run("route", args)?;
        let mut undo: Vec<String> = args.iter().map(|s| s.to_string()).collect();
        undo[1] = "delete".into();
        self.undo.push(undo);
        Ok(())
    }

    fn install(
        utun: &str,
        dns: &str,
        peers: &[String],
        bypass: &[String],
        full_tunnel: bool,
        events: EventBus,
    ) -> Result<Self> {
        let mut r = Self { undo: Vec::new(), dns: Vec::new(), events };
        if !full_tunnel {
            return Ok(r);
        }
        let (gateway, _iface) = physical_default_route()?;
        r.events
            .emit(Event::log(format!("[TUN] macOS physical gateway: {gateway}")));

        // Сервер ядра и пользовательские исключения идут мимо туннеля.
        for ip in peers {
            if let Err(e) = r.add(&["-n", "add", "-host", ip, &gateway]) {
                r.events.emit(Event::error(format!("маршрут к серверу {ip}: {e}")));
            }
        }
        for prefix in bypass {
            if let Err(e) = r.add(&["-n", "add", "-net", prefix, &gateway]) {
                r.events.emit(Event::error(format!("bypass {prefix}: {e}")));
            }
        }
        // Две половины вместо 0.0.0.0/0: физический default остаётся на месте.
        r.add(&["-n", "add", "-net", "0.0.0.0/1", "-interface", utun])?;
        r.add(&["-n", "add", "-net", "128.0.0.0/1", "-interface", utun])?;

        let servers: Vec<String> = dns
            .split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| s.parse::<Ipv4Addr>().is_ok())
            .collect();
        if !servers.is_empty() {
            for service in network_services() {
                let previous = run("networksetup", &["-getdnsservers", &service])
                    .map(|t| {
                        t.lines()
                            .map(str::trim)
                            .filter(|l| l.parse::<std::net::IpAddr>().is_ok())
                            .map(String::from)
                            .collect::<Vec<_>>()
                    })
                    .unwrap_or_default();
                let mut args = vec!["-setdnsservers", service.as_str()];
                args.extend(servers.iter().map(String::as_str));
                if run("networksetup", &args).is_ok() {
                    r.dns.push((service, previous));
                }
            }
        }
        Ok(r)
    }
}

impl Drop for Routes {
    fn drop(&mut self) {
        for (service, previous) in &self.dns {
            let mut args = vec!["-setdnsservers", service.as_str()];
            if previous.is_empty() {
                args.push("Empty");
            } else {
                args.extend(previous.iter().map(String::as_str));
            }
            let _ = run("networksetup", &args);
        }
        for args in self.undo.iter().rev() {
            let refs: Vec<&str> = args.iter().map(String::as_str).collect();
            if let Err(e) = run("route", &refs) {
                self.events
                    .emit(Event::error(format!("не удалось удалить маршрут LaLune: {e}")));
            }
        }
    }
}

pub struct Session {
    handle: Option<JoinHandle<()>>,
}

impl Session {
    #[allow(clippy::too_many_arguments)]
    pub fn start(
        address: &str,
        dns: &str,
        mtu: u16,
        core_port: u16,
        core_pid: u32,
        core_peer: &str,
        running: Arc<AtomicBool>,
        rx: Arc<AtomicU64>,
        tx: Arc<AtomicU64>,
        events: EventBus,
        full_tunnel: bool,
        bypass: Vec<String>,
    ) -> Result<Self> {
        if unsafe { libc::geteuid() } != 0 {
            bail!("Создание utun на macOS требует root (запустите демон с правами администратора)");
        }
        let address: Ipv4Addr = address.parse().context("Некорректный адрес TUN")?;

        // utun-имена выдаёт ядро ОС; перебираем свободные номера.
        let mut created = None;
        let mut last_err = None;
        for n in 9..40 {
            let name = format!("utun{n}");
            let mut config = tun::Configuration::default();
            config
                .name(&name)
                .address(address)
                .destination(address)
                .netmask(Ipv4Addr::new(255, 255, 255, 255))
                .mtu(mtu as i32)
                .up();
            match tun::create_as_async(&config) {
                Ok(dev) => {
                    created = Some((name, dev));
                    break;
                }
                Err(e) => last_err = Some(e),
            }
        }
        let Some((name, dev)) = created else {
            bail!("не удалось создать utun: {}", last_err.map(|e| e.to_string()).unwrap_or_default());
        };
        events.emit(Event::log(format!("[TUN] macOS interface ready: {name} {address} mtu={mtu}")));

        let mut peers = core_remote_ips(core_pid);
        if let Some(ip) = resolve_peer_ipv4(core_peer) {
            let ip = ip.to_string();
            if !peers.contains(&ip) {
                peers.push(ip);
            }
        }

        let socket = UdpSocket::from_std({
            let socket = std::net::UdpSocket::bind("127.0.0.1:0")?;
            socket.connect((Ipv4Addr::LOCALHOST, core_port))?;
            socket.set_nonblocking(true)?;
            socket
        })?;
        let routes = Routes::install(&name, dns, &peers, &bypass, full_tunnel, events.clone())?;
        rx.store(0, Ordering::Relaxed);
        tx.store(0, Ordering::Relaxed);
        running.store(true, Ordering::Release);

        let handle = tokio::spawn(async move {
            let (mut reader, mut writer) = tokio::io::split(dev);
            let _routes = routes; // Drop откатывает маршруты и DNS
            let mut outgoing = vec![0u8; 65535];
            let mut incoming = vec![0u8; 65535];
            let result: Result<()> = async {
                loop {
                    tokio::select! {
                        result = reader.read(&mut outgoing) => {
                            let n = result?;
                            if n == 0 { bail!("TUN закрыт"); }
                            if socket.send(&outgoing[..n]).await? != n { bail!("Неполная отправка пакета ядру"); }
                            tx.fetch_add(n as u64, Ordering::Relaxed);
                        }
                        result = socket.recv(&mut incoming) => {
                            let n = result?;
                            if writer.write(&incoming[..n]).await? != n { bail!("Неполная запись пакета в TUN"); }
                            rx.fetch_add(n as u64, Ordering::Relaxed);
                        }
                    }
                }
            }
            .await;
            running.store(false, Ordering::Release);
            if let Err(error) = result {
                events.emit(Event::error(format!("TUN-мост остановлен: {error}")));
                events.emit(Event::status(false));
            }
        });
        Ok(Self { handle: Some(handle) })
    }

    pub async fn stop(mut self) {
        if let Some(handle) = self.handle.take() {
            handle.abort();
            let _ = handle.await;
        }
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        if let Some(handle) = &self.handle {
            handle.abort();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn resolves_literal_ipv4_with_and_without_port() {
        assert_eq!(resolve_peer_ipv4("1.2.3.4:46000"), Some(Ipv4Addr::new(1, 2, 3, 4)));
        assert_eq!(resolve_peer_ipv4("1.2.3.4"), Some(Ipv4Addr::new(1, 2, 3, 4)));
        assert_eq!(resolve_peer_ipv4(""), None);
    }
}
