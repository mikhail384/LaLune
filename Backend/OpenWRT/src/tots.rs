// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Разбор `tots://` URI для OpenWRT.
//
// Формат тот же, что у десктопного бэкенда: base64url от JSON с полями
// version/peer/webrtc_port/turn_port/password/device_id/provider/provider_data.
// Модуль намеренно повторяет разбор десктопа, чтобы роутер и десктоп
// запускали ядро с одинаковыми аргументами.

use anyhow::{anyhow, Result};
use base64::engine::general_purpose::{URL_SAFE, URL_SAFE_NO_PAD};
use base64::Engine as _;
use serde::Deserialize;
use serde_json::{Map, Value};

#[derive(Debug, Clone, Deserialize)]
pub struct TotsUri {
    #[serde(default)]
    pub version: u32,
    pub peer: String,
    pub webrtc_port: u16,
    pub turn_port: u16,
    pub password: String,
    pub device_id: String,
    pub provider: String,
    #[serde(default)]
    pub provider_data: Map<String, Value>,
    #[serde(default = "default_mtu")]
    pub mtu: u16,
}

fn default_mtu() -> u16 {
    1200
}

/// Разбирает и проверяет `tots://` ссылку.
pub fn parse_uri(link: &str) -> Result<TotsUri> {
    let trimmed = link.trim();
    let payload = trimmed
        .strip_prefix("tots://")
        .or_else(|| trimmed.strip_prefix("ToTS://"))
        .ok_or_else(|| anyhow!("invalid ToTS scheme"))?;
    let encoded = payload.trim();
    let bytes = URL_SAFE_NO_PAD
        .decode(encoded)
        .or_else(|_| URL_SAFE.decode(encoded))
        .map_err(|e| anyhow!("invalid ToTS base64: {e}"))?;
    let uri: TotsUri =
        serde_json::from_slice(&bytes).map_err(|e| anyhow!("invalid ToTS JSON: {e}"))?;
    if uri.version != 1 {
        return Err(anyhow!("unsupported ToTS version {}", uri.version));
    }
    if uri.peer.trim().is_empty() || uri.password.is_empty() || uri.device_id.trim().is_empty() {
        return Err(anyhow!("incomplete ToTS config"));
    }
    if !(576..=1400).contains(&uri.mtu) {
        return Err(anyhow!("invalid ToTS MTU"));
    }
    Ok(uri)
}

/// Собирает `tots://` ссылку обратно из разобранного URI.
///
/// Нужно, когда бэкенд подставляет свежие VK-ссылки перед запуском ядра:
/// аргументы строятся из ссылки, поэтому её надо обновить.
pub fn encode_uri(uri: &TotsUri) -> Option<String> {
    let json = serde_json::json!({
        "version": uri.version,
        "peer": uri.peer,
        "webrtc_port": uri.webrtc_port,
        "turn_port": uri.turn_port,
        "password": uri.password,
        "device_id": uri.device_id,
        "provider": uri.provider,
        "provider_data": serde_json::Value::Object(uri.provider_data.clone()),
        "mtu": uri.mtu,
    });
    let bytes = serde_json::to_vec(&json).ok()?;
    Some(format!(
        "tots://{}",
        URL_SAFE_NO_PAD.encode(bytes)
    ))
}

/// Разбирает ручной JSON-объект provider_data; мусор игнорируется.
pub fn parse_json_object(raw: &str) -> Option<Value> {
    if raw.trim().is_empty() {
        return None;
    }
    serde_json::from_str::<Value>(raw)
        .ok()
        .filter(Value::is_object)
}

/// Приводит список VK-ссылок/хешей к списку ссылок на звонки.
pub fn vk_call_links(raw: &str) -> Vec<String> {
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

/// Нормализует доли воркеров по провайдерам до суммы 100.
///
/// `None`, когда ни один провайдер не включён — тогда ядро использует свои
/// значения по умолчанию.
pub fn normalize_percentages(entries: &[(&str, bool, i32, bool)]) -> Option<Value> {
    let active: Vec<_> = entries
        .iter()
        .filter(|(_, enabled, _, has_data)| *enabled && *has_data)
        .collect();
    if active.is_empty() {
        return None;
    }

    let sum: i32 = active.iter().map(|(_, _, pct, _)| (*pct).clamp(0, 100)).sum();
    let mut out = Map::new();
    if sum <= 0 {
        // Все доли нулевые: отдаём 100 первому провайдеру, как это делает UI.
        for (index, (name, _, _, _)) in active.iter().enumerate() {
            out.insert(
                (*name).to_string(),
                Value::from(if index == 0 { 100 } else { 0 }),
            );
        }
        return Some(Value::Object(out));
    }

    let mut used = 0i32;
    for (index, (name, _, pct, _)) in active.iter().enumerate() {
        let value = if index + 1 == active.len() {
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

#[cfg(test)]
mod tests {
    use super::*;
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;

    fn link(json: &str) -> String {
        format!("tots://{}", URL_SAFE_NO_PAD.encode(json))
    }

    fn valid_json() -> &'static str {
        r#"{"version":1,"peer":"1.2.3.4","webrtc_port":56000,"turn_port":56001,
            "password":"secret","device_id":"0f0e0d0c-0b0a-4908-8706-050403020100",
            "provider":"vk","provider_data":{"vk":{"vk_call_links":["https://vk.ru/call/join/x"]}},
            "mtu":1200}"#
    }

    #[test]
    fn parses_a_valid_link() {
        let uri = parse_uri(&link(valid_json())).expect("parse");
        assert_eq!(uri.peer, "1.2.3.4");
        assert_eq!(uri.webrtc_port, 56000);
        assert_eq!(uri.turn_port, 56001);
        assert_eq!(uri.provider, "vk");
        assert!(uri.provider_data.contains_key("vk"));
    }

    #[test]
    fn rejects_incomplete_or_wrong_version() {
        assert!(parse_uri("tots://").is_err());
        assert!(parse_uri("csqtt://abc").is_err());
        assert!(parse_uri(&link(r#"{"version":2,"peer":"p"}"#)).is_err());
        assert!(parse_uri(&link(r#"{"version":1,"peer":"","password":"x"}"#)).is_err());
        assert!(parse_uri(&link(r#"{"version":1,"peer":"p","password":"x",
            "device_id":"d","mtu":9000}"#)).is_err());
    }

    #[test]
    fn normalizes_percentages_to_one_hundred() {
        let value = normalize_percentages(&[
            ("vk", true, 50, true),
            ("jazz", true, 50, true),
            ("cups", false, 50, true),
        ])
        .expect("percentages");
        assert_eq!(value["vk"], 50);
        assert_eq!(value["jazz"], 50);
        assert!(value.get("cups").is_none(), "disabled providers are dropped");

        // All-zero shares fall back to the first provider taking everything.
        let value = normalize_percentages(&[("vk", true, 0, true), ("jazz", true, 0, true)])
            .expect("percentages");
        assert_eq!(value["vk"], 100);
        assert_eq!(value["jazz"], 0);

        assert!(normalize_percentages(&[("vk", false, 100, true)]).is_none());
    }

    #[test]
    fn round_trips_through_encode() {
        let original = parse_uri(&link(valid_json())).expect("parse");
        let encoded = encode_uri(&original).expect("encode");
        let decoded = parse_uri(&encoded).expect("re-parse");
        assert_eq!(decoded.peer, original.peer);
        assert_eq!(decoded.password, original.password);
        assert_eq!(decoded.device_id, original.device_id);
        assert_eq!(decoded.provider_data, original.provider_data);
    }

    #[test]
    fn converts_hashes_into_join_links() {
        let links = vk_call_links("abc, https://vk.ru/call/join/def;+ghi");
        assert_eq!(
            links,
            vec![
                "https://vk.ru/call/join/abc".to_string(),
                "https://vk.ru/call/join/def".to_string(),
                "https://vk.ru/call/join/ghi".to_string(),
            ]
        );
    }
}
