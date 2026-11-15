// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Policy generation for the Windows process/domain router. The caller owns
// its process lifetime and must verify the underlying tunnel before activation.
use anyhow::{bail, Result};
use serde_json::{json, Value};

#[cfg(target_os = "windows")]
pub fn stop(runtime: &crate::vpn::VpnRuntime) {
    if let Some(mut child) = runtime.split_router.lock().take() {
        let _ = child.kill();
        let _ = child.wait();
    }
}

#[cfg(target_os = "windows")]
pub fn start(runtime: &crate::vpn::VpnRuntime, directory: &std::path::Path,
             config: &Value) -> Result<()> {
    use std::os::windows::process::CommandExt;
    use std::process::{Command, Stdio};
    let exe = std::env::current_exe()?.parent().ok_or_else(|| anyhow::anyhow!("Каталог приложения недоступен"))?.join("sing-box.exe");
    if !exe.is_file() { bail!("Файл sing-box.exe отсутствует рядом с бэкендом"); }
    let path = directory.join("windows-split-routing.json");
    std::fs::write(&path, serde_json::to_vec(config)?)?;
    let check = Command::new(&exe).args(["check", "-c"]).arg(&path)
        .creation_flags(0x08000000).output()?;
    if !check.status.success() { bail!("Настройки маршрутизации отклонены: {}", String::from_utf8_lossy(&check.stderr).trim()); }
    let child = Command::new(exe).args(["run", "-c"]).arg(path)
        .creation_flags(0x08000000).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn()?;
    *runtime.split_router.lock() = Some(child);
    Ok(())
}

#[cfg(target_os = "windows")]
pub fn alive(runtime: &crate::vpn::VpnRuntime) -> bool {
    runtime.split_router.lock().as_mut().is_some_and(|child| matches!(child.try_wait(), Ok(None)))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode { Blacklist, Whitelist }

pub fn build_config(mode: Mode, domains: &[String], programs: &[String],
                    internal_programs: &[String], socks_port: u16) -> Result<Value> {
    if socks_port == 0 { bail!("SOCKS-порт не задан"); }
    if domains.len() > 1000 || programs.len() > 1000 { bail!("Слишком много правил маршрутизации"); }
    let mut normalized = Vec::new();
    for domain in domains {
        let domain = domain.trim().trim_end_matches('.').to_ascii_lowercase();
        if domain.is_empty() || domain.len() > 253 || domain.split('.').any(|part| {
            part.is_empty() || part.len() > 63 || part.starts_with('-') || part.ends_with('-') ||
            !part.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
        }) { bail!("Некорректное доменное имя"); }
        if !normalized.contains(&domain) { normalized.push(domain); }
    }
    let mut apps = Vec::new();
    for program in programs {
        let value = program.trim();
        if value.len() < 4 || value.contains('\0') ||
            !value.as_bytes()[0].is_ascii_alphabetic() || &value.as_bytes()[1..3] != b":\\" ||
            !value.to_ascii_lowercase().ends_with(".exe") {
            bail!("Укажите полный путь к файлу .exe");
        }
        if !apps.iter().any(|path: &String| path.eq_ignore_ascii_case(value)) { apps.push(value.to_string()); }
    }
    if normalized.is_empty() && apps.is_empty() { bail!("Список правил пуст"); }
    let (selected, fallback) = match mode { Mode::Blacklist => ("direct", "tunnel"), Mode::Whitelist => ("tunnel", "direct") };
    let mut rules = vec![json!({"action":"sniff"}), json!({"protocol":"dns", "action":"hijack-dns"})];
    if !internal_programs.is_empty() {
        rules.push(json!({"process_path": internal_programs, "action":"route", "outbound":"direct"}));
    }
    rules.push(json!({"ip_is_private":true, "action":"route", "outbound":"direct"}));
    if !apps.is_empty() { rules.push(json!({"process_path":apps, "action":"route", "outbound":selected})); }
    if !normalized.is_empty() { rules.push(json!({"domain_suffix":normalized, "action":"route", "outbound":selected})); }
    Ok(json!({
        "log": {"level":"warn"},
        "dns": {"servers":[{"type":"udp","tag":"dns-vpn","server":"1.1.1.1","detour":"tunnel"}], "final":"dns-vpn", "strategy":"ipv4_only"},
        "inbounds":[{"type":"tun", "tag":"routing-tun", "interface_name":"LaLune-Routing", "address":["172.29.252.1/30"], "auto_route":true, "strict_route":false}],
        "outbounds":[{"type":"direct","tag":"direct"}, {"type":"socks","tag":"tunnel", "server":"127.0.0.1", "server_port":socks_port}],
        "route":{"rules":rules, "final":fallback, "auto_detect_interface":true}
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn modes_set_opposite_actions() {
        for (mode, selected, default) in [(Mode::Blacklist,"direct","tunnel"), (Mode::Whitelist,"tunnel","direct")] {
            let c = build_config(mode, &["Example.COM".into()], &[r"C:\Apps\Browser.exe".into()], &[], 1080).unwrap();
            assert_eq!(c["route"]["final"], default);
            assert_eq!(c["route"]["rules"][3]["outbound"], selected);
            assert_eq!(c["route"]["rules"][4]["domain_suffix"][0], "example.com");
        }
    }
    #[test]
    fn rejects_bad_rules_and_empty_lists() {
        assert!(build_config(Mode::Blacklist, &[], &[], &[], 1080).is_err());
        assert!(build_config(Mode::Blacklist, &["https://example.com".into()], &[], &[], 1080).is_err());
        assert!(build_config(Mode::Whitelist, &[], &["relative.exe".into()], &[], 1080).is_err());
        assert!(build_config(Mode::Whitelist, &["example.com".into()], &[], &[], 0).is_err());
    }
    #[test]
    fn optionally_export_config_for_engine_validation() {
        if let Ok(path) = std::env::var("LALUNE_SPLIT_CHECK_OUTPUT") {
            let value = build_config(Mode::Blacklist, &["example.com".into()], &[r"C:\Apps\Browser.exe".into()], &[], 1080).unwrap();
            std::fs::write(path, serde_json::to_vec_pretty(&value).unwrap()).unwrap();
        }
    }
}
