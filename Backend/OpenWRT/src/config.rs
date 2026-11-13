// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Конфиги OpenWRT (только CSQTT, без PaperFlux).
//
// Приоритет парсеров csqtt://:
//   1. csqtt-link (Rust, AES-256-GCM)
//   2. Lua (csqtt_decode.lua)
//   3. Нативный fallback

use anyhow::{anyhow, Result};
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use parking_lot::Mutex;

use crate::csqtt_link_bridge;

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ConfigItem {
    pub id: i64,
    pub protocol: String,
    pub peer: String,
    pub password: String,
    pub hashes: String,
    pub name: String,
    #[serde(default)]
    pub raw_link: String,
}

#[derive(Debug, Clone)]
pub struct ConfigStore {
    conn: Arc<Mutex<Connection>>,
}

impl ConfigStore {
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let conn = Connection::open(path)?;
        conn.busy_timeout(Duration::from_secs(5))?;
        conn.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS configs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                protocol TEXT NOT NULL DEFAULT 'CSQTT',
                peer TEXT NOT NULL DEFAULT '',
                password TEXT NOT NULL DEFAULT '',
                hashes TEXT NOT NULL DEFAULT '',
                name TEXT DEFAULT '',
                raw_link TEXT DEFAULT '',
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );
            "#,
        )?;

        let has_raw_link: bool = conn
            .prepare("PRAGMA table_info(configs)")?
            .query_map([], |r| r.get::<_, String>(1))?
            .filter_map(|r| r.ok())
            .any(|name| name == "raw_link");

        if !has_raw_link {
            conn.execute("ALTER TABLE configs ADD COLUMN raw_link TEXT DEFAULT ''", [])?;
        }

        Ok(Self { conn: Arc::new(Mutex::new(conn)) })
    }

    pub fn list(&self) -> Result<Vec<ConfigItem>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT id, protocol, peer, password, hashes, name, raw_link \
             FROM configs ORDER BY id DESC",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok(ConfigItem {
                id: r.get(0)?,
                protocol: r.get(1)?,
                peer: r.get(2)?,
                password: r.get(3)?,
                hashes: r.get(4)?,
                name: r.get(5)?,
                raw_link: r.get(6).unwrap_or_default(),
            })
        })?;
        let mut out = Vec::new();
        for row in rows { out.push(row?); }
        Ok(out)
    }

    pub fn get(&self, id: i64) -> Result<Option<ConfigItem>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT id, protocol, peer, password, hashes, name, raw_link \
             FROM configs WHERE id = ?",
        )?;
        let mut rows = stmt.query(params![id])?;
        if let Some(r) = rows.next()? {
            Ok(Some(ConfigItem {
                id: r.get(0)?,
                protocol: r.get(1)?,
                peer: r.get(2)?,
                password: r.get(3)?,
                hashes: r.get(4)?,
                name: r.get(5)?,
                raw_link: r.get(6).unwrap_or_default(),
            }))
        } else {
            Ok(None)
        }
    }

    pub fn insert(&self, c: &ConfigItem) -> Result<i64> {
        let conn = self.conn.lock();
        conn.execute(
            "INSERT INTO configs (protocol, peer, password, hashes, name, raw_link) \
             VALUES (?, ?, ?, ?, ?, ?)",
            params![c.protocol, c.peer, c.password, c.hashes, c.name, c.raw_link],
        )?;
        Ok(conn.last_insert_rowid())
    }

    pub fn update(&self, id: i64, c: &ConfigItem) -> Result<()> {
        let conn = self.conn.lock();
        let n = conn.execute(
            "UPDATE configs SET protocol=?, peer=?, password=?, hashes=?, name=?, \
             raw_link=?, updated_at=CURRENT_TIMESTAMP WHERE id=?",
            params![c.protocol, c.peer, c.password, c.hashes, c.name, c.raw_link, id],
        )?;
        if n == 0 { return Err(anyhow!("config {} not found", id)); }
        Ok(())
    }

    pub fn delete(&self, id: i64) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute("DELETE FROM configs WHERE id = ?", params![id])?;
        Ok(())
    }
}

pub fn parse_link(link: &str) -> Result<ConfigItem> {
    let link = link.trim();
    let lower = link.to_ascii_lowercase();

    if lower.starts_with("csqtt://") {
        parse_csqtt(link)
    } else if lower.starts_with("olcrtc://") {
        parse_generic(link, "OLCRTC", "olcrtc://")
    } else if lower.starts_with("tots://") {
        parse_generic(link, "TOTS", "tots://")
    } else if lower.starts_with("openflux://") {
        parse_generic(link, "OPENFLUX", "openflux://")
    } else {
        Err(anyhow!("unsupported scheme"))
    }
}

/// The UI (Android/Windows) lets the user paste a link with a caption
/// (`csqttr:csqtt://…`, `CSQTT 2.5.1: csqtt://…`) or with the `csqttr://`
/// scheme. This mirrors the Android backend's `normalizeConfigLink`: it returns
/// the canonical `csqtt://…` link and the core the caption/scheme implies.
pub fn normalize_for_core(
    raw: &str,
    selected: crate::bundled_cores::Core,
) -> (String, crate::bundled_cores::Core) {
    use crate::bundled_cores::Core;
    let trimmed = raw.trim();
    let lower = trimmed.to_ascii_lowercase();
    let mut best: Option<(usize, &str)> = None;
    for scheme in ["csqttr://", "csqtt://", "olcrtc://", "tots://", "openflux://"] {
        if let Some(i) = lower.find(scheme) {
            if best.map_or(true, |(b, _)| i < b) {
                best = Some((i, scheme));
            }
        }
    }
    let Some((idx, scheme)) = best else {
        return (trimmed.to_string(), selected);
    };
    let label = lower[..idx]
        .trim()
        .trim_end_matches(':')
        .trim()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    let uri = trimmed[idx..].lines().next().unwrap_or("").trim();
    let after_scheme = &uri[scheme.len()..];
    let explicit = match label.as_str() {
        "csqtt 2.1.9" => Some(Core::Legacy),
        "csqtt 2.5.1" => Some(Core::Csqtt),
        "csqttr" => Some(Core::Csqttr),
        _ => None,
    };
    let opaque_csqtt = scheme == "csqtt://" && !after_scheme.to_ascii_lowercase().starts_with("connect?");
    let effective = explicit.unwrap_or(if scheme == "csqttr://" {
        Core::Csqttr
    } else if opaque_csqtt && selected == Core::Legacy {
        // Legacy 2.1.9 only understands plain links; an opaque (encrypted)
        // csqtt:// link needs the 2.5.1 core.
        Core::Csqtt
    } else {
        selected
    });
    let canonical = if scheme == "csqttr://" {
        format!("csqtt://{after_scheme}")
    } else {
        uri.to_string()
    };
    (canonical, effective)
}

pub fn parse_for_core(link: &str, core: crate::bundled_cores::Core) -> Result<ConfigItem> {
    let link = link.trim();
    if !link.starts_with("csqtt://") {
        return Err(anyhow!("Для этого ядра нужна ссылка csqtt://"));
    }
    let mut config = if core == crate::bundled_cores::Core::Legacy {
        parse_csqtt_native(link)?
    } else {
        parse_csqtt(link)?
    };
    config.protocol = core.id().into();
    Ok(config)
}

/// CSQTT: csqtt-link → Lua → нативный fallback.
pub fn parse_csqtt(link: &str) -> Result<ConfigItem> {
    // 1. csqtt-link
    match csqtt_link_bridge::parse(link) {
        Ok(parsed) => {
            let mut cfg = ConfigItem::default();
            cfg.protocol = "CSQTT".into();
            cfg.peer = parsed.peer_address();
            cfg.password = parsed.password.clone();
            cfg.hashes = parsed.hashes.join(",");
            cfg.name = parsed.peer_address();
            cfg.raw_link = link.to_string();
            return Ok(cfg);
        }
        Err(e) => {
            log::debug!("[CSQTT] csqtt-link failed: {e:#}; trying Lua fallback");
        }
    }

    // 2. Lua
    if let Some(lua) = crate::lua_runtime::global_runtime() {
        match lua.decode_csqtt_link(link) {
            Ok(decoded) => {
                let mut cfg = ConfigItem::default();
                cfg.protocol = "CSQTT".into();
                cfg.peer = decoded.peer.clone();
                cfg.password = decoded.password.clone();
                cfg.hashes = decoded.hashes.clone();
                cfg.name = if decoded.name.is_empty() {
                    decoded.peer.clone()
                } else {
                    decoded.name.clone()
                };
                cfg.raw_link = link.to_string();
                return Ok(cfg);
            }
            Err(e) => {
                log::debug!("[CSQTT] lua decode failed: {e:#}; trying native fallback");
            }
        }
    }

    // 3. Нативный fallback
    parse_csqtt_native(link)
}

fn parse_csqtt_native(link: &str) -> Result<ConfigItem> {
    let rest = link.trim_start_matches("csqtt://");

    if let Some(query) = rest.strip_prefix("connect?") {
        let mut host = String::new();
        let mut port = String::new();
        let mut password = String::new();
        let mut hashes_raw = String::new();

        for kv in query.split('&') {
            let mut parts = kv.splitn(2, '=');
            let k = parts.next().unwrap_or("");
            let v = parts.next().unwrap_or("");
            match k {
                "host" => host = v.to_string(),
                "peer" => port = v.to_string(),
                "password" => password = v.to_string(),
                "hashes" => hashes_raw = v.to_string(),
                _ => {}
            }
        }

        if host.is_empty() || port.is_empty() || password.is_empty() {
            return Err(anyhow!("csqtt:// missing host/peer/password"));
        }

        let hashes: Vec<String> = hashes_raw
            .split('+')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect();

        let peer = format!("{}:{}", host, port);
        return Ok(ConfigItem {
            id: 0,
            protocol: "CSQTT".into(),
            peer: peer.clone(),
            password,
            hashes: hashes.join(","),
            name: peer.clone(),
            raw_link: link.to_string(),
        });
    }

    if let Some(at) = rest.find('@') {
        let (userinfo, hostport) = rest.split_at(at);
        let hostport = &hostport[1..];
        let password = userinfo.splitn(2, ':').nth(1).unwrap_or("").to_string();
        let peer = if hostport.contains(':') {
            hostport.to_string()
        } else {
            format!("{}:46000", hostport)
        };
        return Ok(ConfigItem {
            id: 0,
            protocol: "CSQTT".into(),
            peer: peer.clone(),
            password,
            hashes: String::new(),
            name: peer,
            raw_link: link.to_string(),
        });
    }

    Err(anyhow!("csqtt:// invalid format"))
}

fn parse_generic(link: &str, protocol: &str, prefix: &str) -> Result<ConfigItem> {
    let rest = link.trim_start_matches(prefix);
    let mut peer = String::new();
    let mut password = String::new();
    let mut hashes = String::new();
    let mut name = String::new();

    for kv in rest.split(';') {
        let mut parts = kv.splitn(2, '=');
        let k = parts.next().unwrap_or("");
        let v = parts.next().unwrap_or("");
        match k {
            "peer" | "host" => peer = v.to_string(),
            "password" => password = v.to_string(),
            "hashes" => hashes = v.replace('+', ","),
            "name" => name = v.to_string(),
            _ => {}
        }
    }

    if peer.is_empty() { return Err(anyhow!("{} missing peer", protocol)); }
    if name.is_empty() { name = peer.clone(); }

    Ok(ConfigItem {
        id: 0,
        protocol: protocol.into(),
        peer,
        password,
        hashes,
        name,
        raw_link: link.to_string(),
    })
}


#[cfg(test)]
mod tests {
    use super::{normalize_for_core, parse_for_core, ConfigItem, ConfigStore};
    use crate::bundled_cores::Core;

    #[test]
    fn caption_and_csqttr_scheme_are_normalized() {
        let plain = "csqtt://connect?v=2&host=1.2.3.4&peer=46000&password=p&hashes=h";
        // Caption in front of the link (what the app lets the user paste).
        assert_eq!(normalize_for_core(&format!("csqttr:{plain}"), Core::Legacy), (plain.into(), Core::Csqttr));
        assert_eq!(normalize_for_core(&format!("CSQTT 2.5.1: {plain}"), Core::Legacy), (plain.into(), Core::Csqtt));
        assert_eq!(normalize_for_core(&format!("csqtt 2.1.9:{plain}"), Core::Csqtt), (plain.into(), Core::Legacy));
        // csqttr:// scheme becomes csqtt:// and selects the CSQTTR core.
        assert_eq!(
            normalize_for_core("csqttr://connect?v=2&host=1.2.3.4", Core::Legacy),
            ("csqtt://connect?v=2&host=1.2.3.4".into(), Core::Csqttr)
        );
        // Opaque (encrypted) csqtt:// link with the legacy core selected needs 2.5.1.
        assert_eq!(normalize_for_core("csqtt://AbCdEf_-123", Core::Legacy), ("csqtt://AbCdEf_-123".into(), Core::Csqtt));
        // Untouched when nothing to normalize; a trailing second line is dropped.
        assert_eq!(normalize_for_core(plain, Core::Csqtt), (plain.into(), Core::Csqtt));
        assert_eq!(normalize_for_core(&format!("{plain}\nnoise"), Core::Csqtt), (plain.into(), Core::Csqtt));
        // Not a known scheme: returned as is.
        assert_eq!(normalize_for_core("vless://x", Core::Csqtt), ("vless://x".into(), Core::Csqtt));
    }

    #[test]
    fn captioned_link_is_accepted_by_parse() {
        let plain = "csqtt://connect?v=2&host=127.0.0.1&peer=46000&password=secret&hashes=h1+h2";
        let (link, core) = normalize_for_core(&format!("csqttr:{plain}"), Core::Legacy);
        let config = parse_for_core(&link, core).expect("captioned CSQTTR link parses");
        assert_eq!(config.protocol, "CSQTTR");
        assert_eq!(config.peer, "127.0.0.1:46000");
    }

    #[test]
    fn csqttr_profile_keeps_protocol_when_parsed() {
        let link = "csqtt://connect?v=2&host=127.0.0.1&peer=46000&password=secret&hashes=h1+h2";
        let config = parse_for_core(link, Core::Csqttr).expect("CSQTTR profile parses");

        assert_eq!(config.protocol, "CSQTTR");
        assert_eq!(config.peer, "127.0.0.1:46000");
        assert_eq!(config.raw_link, link);
    }

    #[test]
    fn sqlite_store_persists_profile() {
        let path = std::env::temp_dir().join(format!("lalune-openwrt-config-test-{}.db", uuid::Uuid::new_v4()));
        let store = ConfigStore::open(&path).expect("open config store");
        let config = ConfigItem {
            protocol: "CSQTTR".into(),
            peer: "127.0.0.1:46000".into(),
            password: "secret".into(),
            hashes: "h1,h2".into(),
            name: "test".into(),
            raw_link: "csqtt://connect?v=2&host=127.0.0.1&peer=46000&password=secret&hashes=h1+h2".into(),
            ..Default::default()
        };

        let id = store.insert(&config).expect("insert config");
        let saved = store.get(id).expect("read config").expect("config exists");
        assert_eq!(saved.protocol, "CSQTTR");
        assert_eq!(saved.raw_link, config.raw_link);

        drop(store);
        let _ = std::fs::remove_file(path);
    }
}
