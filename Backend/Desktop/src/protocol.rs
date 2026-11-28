// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Protocol registry: CSQTT, CSQTTR и ToTS.
// Device ID передаётся только ядру CSQTT 2.1.9.

use anyhow::{anyhow, Result};
use base64::{engine::general_purpose::{URL_SAFE, URL_SAFE_NO_PAD}, Engine as _};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::config::ConfigItem;
use crate::settings::Settings;

pub const CORE_LISTEN_PORT: u16 = 52230;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "UPPERCASE")]
pub enum ProtocolKind {
    Csqtt,
    Csqttr,
    Tots,
    /// WDTToR — Rust-клиент WDTT (WireGuard поверх TURN/DTLS).
    Wdtt,
}

impl ProtocolKind {
    pub fn from_id(s: &str) -> Option<Self> {
        match s.trim().to_ascii_uppercase().as_str() {
            "CSQTT" | "CSQTT 2.1.9" | "CSQTT 2.5.1" => Some(Self::Csqtt),
            "CSQTTR" | "CSQTTR 2.5.2" => Some(Self::Csqttr),
            "TOTS" => Some(Self::Tots),
            // Сравнение идёт по upper-case строке: "WDTToR" → "WDTTOR".
            "WDTTOR" | "WDTTOR (WDTT)" | "WDTTO" | "WDTT" => Some(Self::Wdtt),
            _ => None,
        }
    }

    pub fn id(&self) -> &'static str {
        match self {
            Self::Csqtt => "CSQTT",
            Self::Csqttr => "CSQTTR",
            Self::Tots => "ToTS",
            Self::Wdtt => "WDTToR",
        }
    }

    pub fn display_name(&self) -> &'static str {
        match self {
            Self::Csqtt => "CSQTT (VK Calls)",
            Self::Csqttr => "CSQTTR",
            Self::Tots => "ToTS",
            Self::Wdtt => "WDTToR (WDTT)",
        }
    }

    pub fn repo(&self) -> &'static str {
        match self {
            Self::Csqtt => "Endlad2/csqtt-core",
            Self::Csqttr => "Endlad2/csqttr-core",
            Self::Tots => "Endlad2/ToTS",
            Self::Wdtt => "Endlad2/wdtt-rslib",
        }
    }

    pub fn description(&self) -> &'static str {
        match self {
            Self::Csqtt => "Оригинальный протокол на базе VK Calls, TURN и WRAP.",
            Self::Csqttr => "CSQTTR 2.5.2.",
            Self::Tots => "ToTS: multi-provider transport (VK, Jazz, Ya Docs, Mail Docs, Cups).",
            Self::Wdtt => "WDTToR: WireGuard поверх TURN/DTLS, совместим с сервером WDTT.",
        }
    }

    pub fn core_asset(&self) -> &'static str {
        match self {
            Self::Csqtt => crate::core_manager::csqtt_asset_name(),
            Self::Csqttr => crate::core_manager::csqttr_asset_name(),
            Self::Tots => crate::core_manager::tots_asset_name(),
            Self::Wdtt => crate::core_manager::wdtt_asset_name(),
        }
    }

    pub fn local_filename(&self) -> &'static str {
        match self {
            Self::Csqtt => crate::core_manager::csqtt_local_filename(),
            Self::Csqttr => crate::core_manager::csqttr_local_filename(),
            Self::Tots => crate::core_manager::tots_local_filename(),
            Self::Wdtt => crate::core_manager::wdtt_local_filename(),
        }
    }
}

pub fn supported_protocols() -> Vec<serde_json::Value> {
    vec![
        serde_json::json!({
            "id": "CSQTT 2.1.9",
            "displayName": "CSQTT 2.1.9",
            "repo": "Endlad2/csqtt-core",
            "realtime": true,
            "description": "Plain links; pinned release 2026.09.17.17.36.",
            "coreAsset": crate::core_manager::csqtt_asset_name(),
        }),
        serde_json::json!({
            "id": "CSQTT 2.5.1",
            "displayName": "CSQTT 2.5.1 ⚠",
            "repo": "Endlad2/csqtt-core",
            "realtime": true,
            "description": "Latest CSQTT core; DTLS compatibility warning.",
            "coreAsset": crate::core_manager::csqtt_asset_name(),
        }),
        serde_json::json!({
            "id": "CSQTTR",
            "displayName": "CSQTTR",
            "repo": "Endlad2/csqttr-core",
            "realtime": true,
            "description": "CSQTTR 2.5.2.",
            "coreAsset": crate::core_manager::csqttr_asset_name(),
        }),
        serde_json::json!({
            "id": "ToTS",
            "displayName": "ToTS",
            "repo": "Endlad2/ToTS",
            "realtime": true,
            "description": "Multi-provider ToTS tunnel.",
            "coreAsset": crate::core_manager::tots_asset_name(),
        }),
        serde_json::json!({
            "id": "WDTToR",
            "displayName": "WDTToR (WDTT)",
            "repo": "Endlad2/wdtt-rslib",
            "realtime": true,
            "description": "WireGuard поверх TURN/DTLS, совместим с сервером WDTT.",
            "coreAsset": crate::core_manager::wdtt_asset_name(),
        }),
    ]
}

pub fn settings_keys_for(kind: ProtocolKind) -> Vec<&'static str> {
    match kind {
        ProtocolKind::Csqtt => vec![
            "peer", "vkHashes", "password", "workers", "autoApiWorkers",
            "authMode", "externalHashesUrl", "obfs", "fingerprint", "clientIds",
            "captchaMode", "vkAuthMode", "turnTransport",
            "allowHashRedistribution", "validateVkHashes",
            "shareVpn", "desktopSocks5Mode", "showCoreLogs",
            "ipRoutingMode", "ipRoutingIps",
        ],
        ProtocolKind::Csqttr => vec![
            "peer", "vkHashes", "password", "workers", "autoApiWorkers",
            "authMode", "externalHashesUrl", "obfs", "fingerprint", "clientIds",
            "captchaMode", "vkAuthMode", "turnTransport",
            "allowHashRedistribution", "validateVkHashes",
            "shareVpn", "desktopSocks5Mode", "showCoreLogs",
            "ipRoutingMode", "ipRoutingIps",
        ],
        ProtocolKind::Tots => vec![
            "totsWorkers", "autoApiWorkers", "totsMtu", "totsRelayOnly",
            "totsVkEnabled", "totsJazzEnabled", "totsYaDocsEnabled",
            "totsMailDocsEnabled", "totsCupsEnabled",
            "totsVkPercent", "totsJazzPercent", "totsYaDocsPercent",
            "totsMailDocsPercent", "totsCupsPercent",
            "totsVkAuthMode", "totsVkCallLinks",
            "totsJazzRoomName", "totsJazzRandomName",
            "totsJazzData", "totsYaDocsData", "totsMailDocsData", "totsCupsData",
            "showCoreLogs", "ipRoutingMode", "ipRoutingIps",
        ],
        ProtocolKind::Wdtt => vec![
            "wdttWorkers", "wdttObfs", "wdttVkAuthMode", "wdttLocalPort",
            "wdttDeviceId", "autoApiWorkers",
            "showCoreLogs", "ipRoutingMode", "ipRoutingIps",
        ],
    }
}

pub fn build_args(
    config: &ConfigItem,
    settings: &Settings,
    listen_port: u16,
) -> Result<Vec<String>> {
    let kind = ProtocolKind::from_id(&config.protocol)
        .unwrap_or(ProtocolKind::Csqtt);

    Ok(match kind {
        ProtocolKind::Csqtt | ProtocolKind::Csqttr => build_csqtt_args(config, settings, listen_port),
        ProtocolKind::Tots => build_tots_args(config, settings)?,
        ProtocolKind::Wdtt => build_wdtt_args(config, settings)?,
    })
}

/// Аргументы ядра WDTToR (`wdtt-rslib`).
///
/// Ядро само поднимает WireGuard (boringtun) и TUN, поэтому LaLune не создаёт
/// интерфейс: достаточно передать ссылку и параметры сессий. Хеши VK берутся из
/// конфига в ручном режиме и из `settings.vkHashes` в режиме АвтоAPI (бэкенд
/// подставляет их перед запуском).
fn build_wdtt_args(config: &ConfigItem, settings: &Settings) -> Result<Vec<String>> {
    let raw = config.raw_link.trim();
    let mut args: Vec<String> = Vec::new();

    if raw.to_ascii_lowercase().starts_with("wdtt://") {
        // Ссылка уже содержит пароль и хеши: ядро разбирает её само.
        args.push("--link".into());
        args.push(raw.to_string());
    } else {
        if config.peer.trim().is_empty() {
            anyhow::bail!("WDTToR: пустой peer в конфиге");
        }
        if config.password.trim().is_empty() {
            anyhow::bail!("WDTToR: пустой пароль подключения в конфиге");
        }
        let hashes = if config.hashes.trim().is_empty() {
            settings.vk_hashes.clone()
        } else {
            config.hashes.clone()
        };
        if hashes.trim().is_empty() {
            anyhow::bail!("WDTToR: нет ни одного хеша VK-звонка");
        }
        args.push("--peer".into());
        args.push(config.peer.trim().to_string());
        args.push("--password".into());
        args.push(config.password.clone());
        args.push("--vk".into());
        args.push(hashes);
    }

    args.push("--workers".into());
    args.push(settings.wdtt_workers.max(9).to_string());
    args.push("--obfs".into());
    args.push(settings.wdtt_obfs.clone());
    args.push("--vk-auth-mode".into());
    args.push(settings.vk_auth_mode.clone());
    args.push("--listen".into());
    args.push(format!("127.0.0.1:{}", settings.wdtt_local_port));

    if !settings.wdtt_device_id.trim().is_empty() {
        args.push("--device-id".into());
        args.push(settings.wdtt_device_id.trim().to_string());
    }

    // События в stdout нужны, чтобы UI видел готовность и статистику.
    args.push("--events".into());
    args.push("--log-level".into());
    args.push("info".into());

    Ok(args)
}


#[derive(Debug, Clone, Deserialize)]
pub struct TotsUriConfig {
    #[serde(default)]
    pub version: u32,
    pub peer: String,
    pub webrtc_port: u16,
    pub turn_port: u16,
    pub password: String,
    pub device_id: String,
    pub provider: String,
    #[serde(default)]
    pub provider_data: Value,
    #[serde(default = "default_tots_mtu")]
    pub mtu: u16,
}

fn default_tots_mtu() -> u16 { 1200 }

pub fn parse_tots_uri(link: &str) -> Result<TotsUriConfig> {
    let trimmed = link.trim();
    let payload = trimmed.strip_prefix("tots://")
        .or_else(|| trimmed.strip_prefix("ToTS://"))
        .ok_or_else(|| anyhow!("invalid ToTS scheme"))?;
    let encoded = payload.trim();
    let bytes = URL_SAFE_NO_PAD.decode(encoded)
        .or_else(|_| URL_SAFE.decode(encoded))
        .map_err(|e| anyhow!("invalid ToTS base64: {e}"))?;
    let cfg: TotsUriConfig = serde_json::from_slice(&bytes)
        .map_err(|e| anyhow!("invalid ToTS JSON: {e}"))?;
    if cfg.version != 1 { return Err(anyhow!("unsupported ToTS version {}", cfg.version)); }
    if cfg.peer.trim().is_empty() || cfg.password.is_empty() || cfg.device_id.trim().is_empty() {
        return Err(anyhow!("incomplete ToTS config"));
    }
    if !(576..=1400).contains(&cfg.mtu) { return Err(anyhow!("invalid ToTS MTU")); }
    Ok(cfg)
}

fn parse_json_object(raw: &str) -> Option<Value> {
    if raw.trim().is_empty() { return None; }
    serde_json::from_str::<Value>(raw).ok().filter(Value::is_object)
}

fn tots_vk_call_links(raw: &str) -> Vec<String> {
    raw.split(|c: char| c == ',' || c == '+' || c == ';' || c.is_whitespace())
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .map(|v| {
            if v.starts_with("https://") || v.starts_with("http://") {
                v.to_owned()
            } else {
                format!("https://vk.ru/call/join/{v}")
            }
        })
        .collect()
}

fn normalize_worker_percentages(entries: &[(&str, bool, i32, bool)]) -> Option<Value> {
    let active: Vec<_> = entries.iter()
        .filter(|(_, enabled, _, has_data)| *enabled && *has_data)
        .collect();
    if active.is_empty() { return None; }

    let sum: i32 = active.iter().map(|(_, _, pct, _)| (*pct).clamp(0, 100)).sum();
    let mut out = Map::new();
    if sum <= 0 {
        for (idx, (name, _, _, _)) in active.iter().enumerate() {
            out.insert((*name).to_string(), Value::from(if idx == 0 { 100 } else { 0 }));
        }
        return Some(Value::Object(out));
    }

    let mut used = 0i32;
    for (idx, (name, _, pct, _)) in active.iter().enumerate() {
        let value = if idx + 1 == active.len() {
            100 - used
        } else {
            let scaled = ((*pct).clamp(0, 100) * 100) / sum;
            used += scaled;
            scaled
        };
        out.insert((*name).to_string(), Value::from(value));
    }
    Some(Value::Object(out))
}

fn validate_jazz_worker_capacity(data: &Value, requested_workers: usize) -> Result<()> {
    let jazz = data.as_object().ok_or_else(|| anyhow!("Jazz provider_data must be an object"))?;
    let room_count = if let Some(value) = jazz.get("worker_rooms") {
        let rooms = value.as_array().ok_or_else(|| anyhow!("Jazz worker_rooms must be an array"))?;
        if rooms.is_empty() || rooms.len() > 50 {
            return Err(anyhow!("Jazz worker_rooms must contain 1..=50 server-provisioned rooms"));
        }
        if let Some(count) = jazz.get("worker_count") {
            if count.as_u64() != Some(rooms.len() as u64) {
                return Err(anyhow!("Jazz worker_count does not match worker_rooms ({} rooms)", rooms.len()));
            }
        }
        let mut links = std::collections::HashSet::new();
        for (index, room) in rooms.iter().enumerate() {
            let object = room.as_object().ok_or_else(|| anyhow!("Jazz worker_rooms[{}] is invalid", index))?;
            let join_link = object.get("join_link").and_then(Value::as_str).unwrap_or("").trim();
            let connector = object.get("connector_url").and_then(Value::as_str).unwrap_or("").trim();
            if join_link.is_empty() || connector.is_empty() || !links.insert(join_link) {
                return Err(anyhow!("Jazz worker_rooms[{}] is incomplete or duplicated", index));
            }
        }
        rooms.len()
    } else {
        // A legacy invite provides one slot. worker_count alone is only a
        // provisioning request and cannot manufacture server-side bridges.
        if jazz.get("join_link").and_then(Value::as_str).unwrap_or("").trim().is_empty() {
            return Err(anyhow!("Jazz provider_data has no server-provisioned join_link"));
        }
        1
    };

    if room_count < requested_workers {
        return Err(anyhow!(
            "Jazz has {} provisioned room(s), but ToTS --n {} requires {}. Create a new ToTS config through the server API with provider_data.jazz.worker_count={}; do not change worker_count manually.",
            room_count, requested_workers, requested_workers, requested_workers
        ));
    }
    Ok(())
}

fn build_tots_args(config: &ConfigItem, settings: &Settings) -> Result<Vec<String>> {
    // Always decode the URI and pass explicit flags. Intentionally never use --config.
    let parsed = parse_tots_uri(&config.raw_link)?;
    let mut provider_data = parsed.provider_data.as_object().cloned().unwrap_or_default();

    let enabled = [
        ("vk", settings.tots_vk_enabled),
        ("jazz", settings.tots_jazz_enabled),
        ("ya-docs", settings.tots_ya_docs_enabled),
        ("mail-docs", settings.tots_mail_docs_enabled),
        ("cups", settings.tots_cups_enabled),
    ];
    for (name, is_enabled) in enabled {
        if !is_enabled { provider_data.remove(name); }
    }

    if settings.tots_vk_enabled && !settings.tots_vk_call_links.trim().is_empty() {
        let links = tots_vk_call_links(&settings.tots_vk_call_links);
        if !links.is_empty() {
            let mut vk = provider_data.get("vk")
                .and_then(Value::as_object)
                .cloned()
                .unwrap_or_default();
            vk.insert("vk_call_links".into(), serde_json::json!(links));
            provider_data.insert("vk".into(), Value::Object(vk));
        }
    }
    for (name, raw, is_enabled) in [
        ("jazz", settings.tots_jazz_data.as_str(), settings.tots_jazz_enabled),
        ("ya-docs", settings.tots_ya_docs_data.as_str(), settings.tots_ya_docs_enabled),
        ("mail-docs", settings.tots_mail_docs_data.as_str(), settings.tots_mail_docs_enabled),
        ("cups", settings.tots_cups_data.as_str(), settings.tots_cups_enabled),
    ] {
        if is_enabled {
            if let Some(value) = parse_json_object(raw) { provider_data.insert(name.into(), value); }
        }
    }
    if settings.tots_jazz_enabled {
        if let Some(jazz) = provider_data.get_mut("jazz") {
            validate_jazz_worker_capacity(jazz, settings.tots_workers.clamp(1, 256) as usize)?;
            if let Some(object) = jazz.as_object_mut() {
                if !settings.tots_jazz_room_name.trim().is_empty() {
                    object.insert("name".into(), Value::String(settings.tots_jazz_room_name.trim().to_string()));
                }
            }
        }
    }

    if provider_data.is_empty() { return Err(anyhow!("ToTS provider_data is empty after applying enabled providers")); }
    let provider = if provider_data.contains_key(&parsed.provider) {
        parsed.provider.clone()
    } else {
        ["vk", "jazz", "ya-docs", "mail-docs", "cups"].into_iter()
            .find(|name| provider_data.contains_key(*name)).unwrap_or("vk").to_string()
    };

    let has = |name: &str| provider_data.contains_key(name);
    let percentages = normalize_worker_percentages(&[
        ("vk", settings.tots_vk_enabled, settings.tots_vk_percent, has("vk")),
        ("jazz", settings.tots_jazz_enabled, settings.tots_jazz_percent, has("jazz")),
        ("ya-docs", settings.tots_ya_docs_enabled, settings.tots_ya_docs_percent, has("ya-docs")),
        ("mail-docs", settings.tots_mail_docs_enabled, settings.tots_mail_docs_percent, has("mail-docs")),
        ("cups", settings.tots_cups_enabled, settings.tots_cups_percent, has("cups")),
    ]);

    let mut args = vec![
        "--peer".into(), parsed.peer,
        "--webrtc-port".into(), parsed.webrtc_port.to_string(),
        "--turn-port".into(), parsed.turn_port.to_string(),
        "--password".into(), parsed.password,
        "--device-id".into(), parsed.device_id,
        "--provider".into(), provider,
        "--provider-data".into(), Value::Object(provider_data).to_string(),
        "--n".into(), settings.tots_workers.clamp(1, 256).to_string(),
        "--mtu".into(), settings.tots_mtu.clamp(576, 1400).to_string(),
    ];
    if let Some(pct) = percentages {
        args.push("--workers_percent".into());
        args.push(pct.to_string());
    }
    if settings.tots_relay_only { args.push("--relay-only".into()); }
    args.push("--tun-name".into());
    args.push(crate::vpn::TOTS_TUN_NAME.into());
    args.push("--tun-default-route".into());
    Ok(args)
}

fn build_csqtt_args(
    config: &ConfigItem,
    settings: &Settings,
    listen_port: u16,
) -> Vec<String> {
    // Fallback: если в конфиге хешей нет — берём из settings.vk_hashes.
    // Это позволяет UI сохранять хеши в settings.vkHashes и не привязывать
    // их к конкретному ConfigItem.
    let source_hashes = if config.hashes.trim().is_empty() {
        settings.vk_hashes.as_str()
    } else {
        config.hashes.as_str()
    };

    let normalized = source_hashes.replace([' ', '\t', '\n', '\r'], ",");
    let clean: Vec<String> = normalized
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .take(6)
        .collect();

    let hashes = if clean.is_empty() { String::new() } else { clean.join(",") };

    let auth_mode = if settings.auth_mode.is_empty() {
        "manual".to_string()
    } else {
        settings.auth_mode.clone()
    };
    let is_auto_vk = auth_mode == "autoVk";

    let hash_mode = if is_auto_vk { "auto_js" } else { "manual" };
    let vk_auth_mode = if is_auto_vk {
        "auto_js"
    } else if settings.vk_auth_mode.is_empty() {
        "vkcalls"
    } else {
        settings.vk_auth_mode.as_str()
    };

    let workers = settings.workers.clamp(
        crate::settings::MIN_WORKERS,
        crate::settings::MAX_WORKERS,
    );

    let mut args: Vec<String> = vec![
        "--peer".into(), config.peer.clone(),
        "--password".into(), config.password.clone(),
        "--vk-hash-mode".into(), hash_mode.into(),
        "--vk-auth-mode".into(), vk_auth_mode.into(),
        "--listen".into(), format!("127.0.0.1:{}", listen_port),
        "-n".into(), workers.to_string(),
        "--obfs".into(), settings.obfs.clone(),
        "--fingerprint".into(), settings.fingerprint.clone(),
        "--client-ids".into(), settings.client_ids.clone(),
        "--captcha-mode".into(), settings.captcha_mode.clone(),
        "--turn-transport".into(), settings.turn_transport.clone(),
    ];

    if !is_auto_vk {
        args.push("--vk".into());
        args.push(hashes);
    }

    if is_auto_vk {
        if let Some(token) = read_vk_token_for_core() {
            args.push("--token".into());
            args.push(token);
        }
    }

    if config.protocol.trim().eq_ignore_ascii_case("CSQTT 2.1.9")
        && !settings.device_id.trim().is_empty()
    {
        args.push("--device-id".into());
        args.push(settings.device_id.trim().to_string());
    }

    if !settings.turn_host.is_empty() {
        args.push("--turn".into());
        args.push(settings.turn_host.clone());
    }
    if !settings.turn_port.is_empty() {
        args.push("--port".into());
        args.push(settings.turn_port.clone());
    }
    if settings.allow_hash_redistribution {
        args.push("--allow-hash-redistribution".into());
    }
    if settings.validate_vk_hashes {
        args.push("--validate-vk-hashes".into());
    }

    args
}

fn read_vk_token_for_core() -> Option<String> {
    let dir = crate::state::app_dir().ok()?;
    crate::vk::read_token(&dir)
}

pub fn link_placeholder(kind: ProtocolKind) -> &'static str {
    match kind {
        ProtocolKind::Csqtt | ProtocolKind::Csqttr => {
            "csqtt://connect?v=2&host=...&peer=...&password=...&hashes=h1+h2"
        }
        ProtocolKind::Tots => "tots://<base64url-json>",
        ProtocolKind::Wdtt => "wdtt://host:56000:56001:9000:пароль:хеш1,хеш2",
    }
}


#[cfg(test)]
mod jazz_pool_validation_tests {
    use super::validate_jazz_worker_capacity;
    use serde_json::json;

    #[test]
    fn rejects_a_single_room_for_a_multi_worker_pool() {
        let data = json!({"join_link":"invite"});
        let error = validate_jazz_worker_capacity(&data, 30).unwrap_err().to_string();
        assert!(error.contains("has 1 provisioned room"));
        assert!(error.contains("--n 30"));
    }

    #[test]
    fn accepts_a_server_provisioned_pool_with_matching_count() {
        let data = json!({
            "worker_count": 2,
            "worker_rooms": [
                {"join_link":"room-1", "connector_url":"connector-1"},
                {"join_link":"room-2", "connector_url":"connector-2"}
            ]
        });
        assert!(validate_jazz_worker_capacity(&data, 2).is_ok());
    }

    #[test]
    fn rejects_mismatched_worker_count_and_room_array() {
        let data = json!({
            "worker_count": 30,
            "worker_rooms": [{"join_link":"room-1", "connector_url":"connector-1"}]
        });
        let error = validate_jazz_worker_capacity(&data, 1).unwrap_err().to_string();
        assert!(error.contains("does not match worker_rooms"));
    }
}

#[cfg(test)]
mod wdtt_tests {
    use super::*;
    use crate::config::ConfigItem;

    const REAL_LINK: &str = "wdtt://82.40.38.237:56005:56006:9000:uVCF2Nf6dZK8hEKe:sBvxpZXkz_CAoAstXFslhAZmukJ8rI54l8sJDEbQOO4,BRtpXEy74qSrZ-6A6QS5THpi9qoQx7-4JzBRWU4f9Q0,Yb_jusGtRZxh3MFVSmbOqVb6cZm5McRKzrH4YPWE_xM";

    fn config_with_link(link: &str) -> ConfigItem {
        ConfigItem {
            id: 0,
            protocol: "WDTToR".into(),
            peer: String::new(),
            password: String::new(),
            hashes: String::new(),
            name: "test".into(),
            raw_link: link.into(),
        }
    }

    #[test]
    fn wdtt_is_advertised_to_the_ui() {
        let protocols = supported_protocols();
        let wdtt = protocols
            .iter()
            .find(|p| p.get("id").and_then(|v| v.as_str()) == Some("WDTToR"))
            .expect("WDTToR must be advertised");
        assert_eq!(
            wdtt.get("displayName").and_then(|v| v.as_str()),
            Some("WDTToR (WDTT)"),
            "UI label must be «WDTToR (WDTT)»"
        );
        assert_eq!(
            wdtt.get("repo").and_then(|v| v.as_str()),
            Some("Endlad2/wdtt-rslib")
        );
        assert!(!wdtt
            .get("coreAsset")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .is_empty());
        // The link placeholder shown in the add-config dialog.
        assert_eq!(
            link_placeholder(ProtocolKind::Wdtt),
            "wdtt://host:56000:56001:9000:пароль:хеш1,хеш2"
        );
    }

    #[test]
    fn recognizes_wdtt_ids() {
        for id in ["WDTToR", "wdtto", "WDTT", "WDTToR (WDTT)"] {
            assert_eq!(ProtocolKind::from_id(id), Some(ProtocolKind::Wdtt), "{id}");
        }
        assert_eq!(ProtocolKind::Wdtt.id(), "WDTToR");
        assert_eq!(ProtocolKind::Wdtt.display_name(), "WDTToR (WDTT)");
        assert_eq!(ProtocolKind::Wdtt.local_filename(), "wdtt-core");
    }

    #[test]
    fn link_is_passed_through_verbatim() {
        let settings = Settings::default();
        let args = build_wdtt_args(&config_with_link(REAL_LINK), &settings).unwrap();
        let idx = args.iter().position(|a| a == "--link").expect("--link");
        assert_eq!(args[idx + 1], REAL_LINK);
        // The password must not be duplicated on the command line.
        assert!(!args.iter().any(|a| a == "--password"));
        // Events are always on so the UI sees readiness.
        assert!(args.iter().any(|a| a == "--events"));
    }

    #[test]
    fn manual_mode_uses_config_hashes() {
        let mut settings = Settings::default();
        settings.wdtt_workers = 18;
        settings.wdtt_obfs = "video".into();
        settings.wdtt_local_port = 9100;
        let config = ConfigItem {
            peer: "1.2.3.4:56005".into(),
            password: "secret".into(),
            hashes: "hashone1,hashtwo2".into(),
            ..config_with_link("")
        };
        let args = build_wdtt_args(&config, &settings).unwrap();
        let value = |flag: &str| -> String {
            let i = args.iter().position(|a| a == flag).expect(flag);
            args[i + 1].clone()
        };
        assert_eq!(value("--peer"), "1.2.3.4:56005");
        assert_eq!(value("--password"), "secret");
        assert_eq!(value("--vk"), "hashone1,hashtwo2");
        assert_eq!(value("--workers"), "18");
        assert_eq!(value("--obfs"), "video");
        assert_eq!(value("--listen"), "127.0.0.1:9100");
    }

    #[test]
    fn auto_api_mode_falls_back_to_settings_hashes() {
        let mut settings = Settings::default();
        settings.wdtt_vk_auth_mode = "autoApi".into();
        settings.vk_hashes = "fromApi123,fromApi456".into();
        let config = ConfigItem {
            peer: "1.2.3.4:56005".into(),
            password: "secret".into(),
            hashes: String::new(),
            ..config_with_link("")
        };
        let args = build_wdtt_args(&config, &settings).unwrap();
        let i = args.iter().position(|a| a == "--vk").expect("--vk");
        assert_eq!(args[i + 1], "fromApi123,fromApi456");
    }

    #[test]
    fn missing_credentials_are_rejected() {
        let settings = Settings::default();
        let no_peer = ConfigItem {
            password: "secret".into(),
            hashes: "h1".into(),
            ..config_with_link("")
        };
        assert!(build_wdtt_args(&no_peer, &settings).is_err());

        let no_password = ConfigItem {
            peer: "1.2.3.4:56005".into(),
            hashes: "h1".into(),
            ..config_with_link("")
        };
        assert!(build_wdtt_args(&no_password, &settings).is_err());

        let no_hashes = ConfigItem {
            peer: "1.2.3.4:56005".into(),
            password: "secret".into(),
            ..config_with_link("")
        };
        assert!(build_wdtt_args(&no_hashes, &settings).is_err());
    }

    #[test]
    fn worker_count_is_normalized() {
        let mut settings = Settings::default();
        settings.wdtt_workers = 0;
        settings.normalize();
        assert_eq!(settings.wdtt_workers, 9);

        settings.wdtt_workers = 20;
        settings.normalize();
        assert_eq!(settings.wdtt_workers, 18, "must round down to a multiple of 9");

        settings.wdtt_workers = 500;
        settings.normalize();
        assert_eq!(settings.wdtt_workers, 108);
    }

    #[test]
    fn settings_normalize_sanitizes_wdtt_fields() {
        let mut settings = Settings::default();
        settings.wdtt_obfs = "nonsense".into();
        settings.wdtt_vk_auth_mode = "weird".into();
        settings.wdtt_local_port = 1;
        settings.normalize();
        assert_eq!(settings.wdtt_obfs, "audio");
        assert_eq!(settings.wdtt_vk_auth_mode, "manual");
        assert_eq!(settings.wdtt_local_port, 1024);
    }
}
