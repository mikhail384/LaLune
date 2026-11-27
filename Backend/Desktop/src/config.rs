// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Конфиги: SQLite-хранилище + парсинг поддерживаемых ссылок.
//
// Приоритет парсеров для csqtt://:
//   1. csqtt-link (Rust, AES-256-GCM) — основной
//   2. Lua (csqtt_decode.lua) — если пользователь положил файл
//   3. Нативный (plain v=2 / user:pass@host) — fallback
//
// Логирование: щедрое, на уровне INFO/WARN, чтобы всё было видно
// в /logs/tail и в stderr бэкенда без RUST_LOG=debug.

use anyhow::{anyhow, Result};
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use std::path::Path;
use std::sync::Arc;
use parking_lot::Mutex;

use crate::csqtt_link_bridge;

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ConfigItem {
    pub id: i64,
    #[serde(default)]
    pub protocol: String,
    #[serde(default)]
    pub peer: String,
    #[serde(default)]
    pub password: String,
    #[serde(default)]
    pub hashes: String,
    #[serde(default)]
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
        log::info!("[CONFIG] opening SQLite at {}", path.display());
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let conn = Connection::open(path)?;
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

        let existing: Vec<String> = conn
            .prepare("PRAGMA table_info(configs)")?
            .query_map([], |r| r.get::<_, String>(1))?
            .filter_map(|r| r.ok())
            .collect();
        if !existing.iter().any(|c| c == "raw_link") {
            conn.execute("ALTER TABLE configs ADD COLUMN raw_link TEXT DEFAULT ''", [])?;
        }

        log::info!("[CONFIG] SQLite ready");
        Ok(Self { conn: Arc::new(Mutex::new(conn)) })
    }

    fn row_to_item(r: &rusqlite::Row) -> rusqlite::Result<ConfigItem> {
        Ok(ConfigItem {
            id: r.get(0)?,
            protocol: r.get::<_, String>(1).unwrap_or_else(|_| "CSQTT".into()),
            peer: r.get::<_, String>(2).unwrap_or_default(),
            password: r.get::<_, String>(3).unwrap_or_default(),
            hashes: r.get::<_, String>(4).unwrap_or_default(),
            name: r.get::<_, String>(5).unwrap_or_default(),
            raw_link: r.get::<_, String>(6).unwrap_or_default(),
        })
    }

    const SELECT_COLS: &'static str =
        "id, protocol, peer, password, hashes, name, raw_link";

    pub fn list(&self) -> Result<Vec<ConfigItem>> {
        let conn = self.conn.lock();
        let sql = format!("SELECT {} FROM configs ORDER BY id DESC", Self::SELECT_COLS);
        let mut stmt = conn.prepare(&sql)?;
        let rows = stmt.query_map([], Self::row_to_item)?;
        let mut out = Vec::new();
        for row in rows { out.push(row?); }
        log::info!("[CONFIG] list: {} configs", out.len());
        Ok(out)
    }

    pub fn get(&self, id: i64) -> Result<Option<ConfigItem>> {
        let conn = self.conn.lock();
        let sql = format!("SELECT {} FROM configs WHERE id = ?", Self::SELECT_COLS);
        let mut stmt = conn.prepare(&sql)?;
        let mut rows = stmt.query(params![id])?;
        if let Some(r) = rows.next()? {
            Ok(Some(Self::row_to_item(r)?))
        } else {
            Ok(None)
        }
    }

    pub fn insert(&self, c: &ConfigItem) -> Result<i64> {
        log::info!(
            "[CONFIG] insert: protocol={} peer={} password_len={} hashes_len={} name={}",
            c.protocol, c.peer, c.password.len(), c.hashes.len(), c.name
        );
        let conn = self.conn.lock();
        conn.execute(
            "INSERT INTO configs (protocol, peer, password, hashes, name, raw_link)
             VALUES (?,?,?,?,?,?)",
            params![c.protocol, c.peer, c.password, c.hashes, c.name, c.raw_link],
        )?;
        let id = conn.last_insert_rowid();
        log::info!("[CONFIG] inserted id={}", id);
        Ok(id)
    }

    pub fn update(&self, id: i64, c: &ConfigItem) -> Result<()> {
        log::info!("[CONFIG] update id={} protocol={}", id, c.protocol);
        let conn = self.conn.lock();
        let n = conn.execute(
            "UPDATE configs SET
                protocol=?, peer=?, password=?, hashes=?, name=?, raw_link=?,
                updated_at=CURRENT_TIMESTAMP
             WHERE id=?",
            params![c.protocol, c.peer, c.password, c.hashes, c.name, c.raw_link, id],
        )?;
        if n == 0 { return Err(anyhow!("config {} not found", id)); }
        log::info!("[CONFIG] updated id={}", id);
        Ok(())
    }

    pub fn delete(&self, id: i64) -> Result<()> {
        log::info!("[CONFIG] delete id={}", id);
        let conn = self.conn.lock();
        conn.execute("DELETE FROM configs WHERE id = ?", params![id])?;
        Ok(())
    }
}

// ============================================================
//  Парсинг ссылок
// ============================================================

fn short_link(link: &str) -> String {
    let s = link.trim();
    if s.chars().count() <= 80 {
        s.to_string()
    } else {
        let head: String = s.chars().take(60).collect();
        let tail: String = s.chars().rev().take(12).collect::<String>()
            .chars().rev().collect();
        format!("{}...{} (len={})", head, tail, s.chars().count())
    }
}

pub fn parse_link(link: &str) -> Result<ConfigItem> {
    parse_link_for_protocol(link, "CSQTT")
}

/// CSQTT 2.1.9 uses a plain, unencrypted link format; do not send it through csqtt-link.
pub fn parse_link_for_protocol(link: &str, protocol: &str) -> Result<ConfigItem> {
    let link = link.trim();
    if protocol.trim().eq_ignore_ascii_case("CSQTT 2.1.9")
        && link.to_ascii_lowercase().starts_with("csqtt://")
    {
        let mut config = parse_csqtt_native(link)?;
        config.protocol = "CSQTT 2.1.9".into();
        config.raw_link = link.to_string();
        log::info!("[PARSE][CSQTT 2.1.9] parsed plain link without csqtt-link");
        return Ok(config);
    }
    let lower = link.to_ascii_lowercase();

    log::info!("[PARSE] scheme-detect link={}", short_link(link));

    if lower.starts_with("csqtt://") {
        let mut config = parse_csqtt(link)?;
        let requested = protocol.trim();
        if requested.eq_ignore_ascii_case("CSQTT 2.5.1") {
            config.protocol = "CSQTT 2.5.1".into();
        } else if requested.eq_ignore_ascii_case("CSQTTR")
            || requested.eq_ignore_ascii_case("CSQTTR 2.5.2")
        {
            config.protocol = "CSQTTR".into();
        }
        Ok(config)
    } else if lower.starts_with("olcrtc://") {
        parse_generic(link, "OLCRTC", "olcrtc://")
    } else if lower.starts_with("tots://") {
        parse_tots(link)
    } else if lower.starts_with("wdtt://") {
        parse_wdtt(link)
    } else {
        log::warn!("[PARSE] unsupported scheme: {:?}", &link.chars().take(20).collect::<String>());
        Err(anyhow!("unsupported scheme"))
    }
}

/// Разбирает ссылку WDTToR: `wdtt://host:dtls:wg:local:password:hashes`.
///
/// Пароль и хеши хранятся в конфиге отдельно (чтобы UI мог их показать и чтобы
/// АвтоAPI мог заменить хеши), а `raw_link` сохраняется целиком — ядро умеет
/// разбирать его само.
fn parse_wdtt(link: &str) -> Result<ConfigItem> {
    let body = link
        .trim()
        .strip_prefix("wdtt://")
        .or_else(|| link.trim().strip_prefix("WDTToR://"))
        .ok_or_else(|| anyhow!("invalid wdtt:// link"))?;

    // host:dtls:wg:local:password:hashes — пароль не содержит ':', хеши
    // разделены запятыми, поэтому splitn(6) безопасен.
    let parts: Vec<&str> = body.splitn(6, ':').collect();
    if parts.len() < 5 {
        return Err(anyhow!(
            "wdtt:// link needs host:dtls:wg:local:password:hashes, got {} field(s)",
            parts.len()
        ));
    }

    let host = parts[0].trim();
    if host.is_empty() {
        return Err(anyhow!("wdtt:// link has no server address"));
    }
    let dtls_port = parts[1].trim();
    let password = parts[4].trim().to_string();
    if password.is_empty() {
        return Err(anyhow!("wdtt:// link has no connection password"));
    }
    let hashes = parts.get(5).map(|h| h.trim().to_string()).unwrap_or_default();

    let mut config = ConfigItem {
        id: 0,
        protocol: "WDTToR".into(),
        peer: if dtls_port.is_empty() {
            host.to_string()
        } else {
            format!("{host}:{dtls_port}")
        },
        password,
        hashes,
        name: String::new(),
        raw_link: link.trim().to_string(),
    };
    if config.name.is_empty() {
        config.name = format!("WDTToR {}", host);
    }
    log::info!("[PARSE][WDTToR] parsed link for {host}");
    Ok(config)
}

/// Парсит csqtt:// ссылку.
/// Приоритет: csqtt-link → Lua → нативный.
pub fn parse_csqtt(link: &str) -> Result<ConfigItem> {
    log::info!("[PARSE][CSQTT] === start ===");
    log::info!("[PARSE][CSQTT] raw link = {}", short_link(link));

    // ---- 1. csqtt-link ----
    log::info!("[PARSE][CSQTT] trying csqtt-link (AES-256-GCM)...");
    match csqtt_link_bridge::parse(link) {
        Ok(parsed) => {
            log::info!(
                "[PARSE][CSQTT] csqtt-link OK: host={} port={} password_len={} hashes={}",
                parsed.host, parsed.port, parsed.password.len(), parsed.hashes.len()
            );
            let mut cfg = ConfigItem::default();
            cfg.protocol = "CSQTT".into();
            cfg.peer = parsed.peer_address();
            cfg.password = parsed.password.clone();
            cfg.hashes = parsed.hashes.join(",");
            cfg.name = parsed.peer_address();
            cfg.raw_link = link.to_string();
            log::info!("[PARSE][CSQTT] === success via csqtt-link ===");
            return Ok(cfg);
        }
        Err(e) => {
            log::warn!("[PARSE][CSQTT] csqtt-link FAILED: {:#}", e);
        }
    }

    // ---- 2. Lua ----
    let lua = crate::lua_runtime::global_runtime();
    match lua {
        Some(lua) => {
            log::info!("[PARSE][CSQTT] trying Lua (csqtt_decode.lua)...");
            match lua.decode_csqtt_link(link) {
                Ok(decoded) => {
                    log::info!(
                        "[PARSE][CSQTT] lua OK: peer={} password_len={} hashes_len={}",
                        decoded.peer, decoded.password.len(), decoded.hashes.len()
                    );
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
                    log::info!("[PARSE][CSQTT] === success via Lua ===");
                    return Ok(cfg);
                }
                Err(e) => {
                    log::warn!("[PARSE][CSQTT] Lua FAILED: {:#}", e);
                }
            }
        }
        None => {
            log::warn!("[PARSE][CSQTT] Lua runtime not initialized, skip");
        }
    }

    // ---- 3. Нативный fallback ----
    log::info!("[PARSE][CSQTT] trying native fallback (plain v=2 / user:pass@host)...");
    match parse_csqtt_native(link) {
        Ok(cfg) => {
            log::info!("[PARSE][CSQTT] === success via native fallback ===");
            Ok(cfg)
        }
        Err(e) => {
            log::error!("[PARSE][CSQTT] native fallback FAILED: {:#}", e);
            log::error!("[PARSE][CSQTT] === all parsers failed ===");
            Err(anyhow!(
                "csqtt:// invalid format (csqtt-link: not AES-GCM; lua: unavailable; native: expected connect?v=2 or user:pass@host)"
            ))
        }
    }
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
            return Err(anyhow!("csqtt://connect? missing host/peer/password"));
        }

        let hashes: Vec<String> = hashes_raw
            .split('+')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect();

        let peer = format!("{}:{}", host, port);
        let mut cfg = ConfigItem::default();
        cfg.protocol = "CSQTT".into();
        cfg.peer = peer.clone();
        cfg.password = password;
        cfg.hashes = hashes.join(",");
        cfg.name = peer.clone();
        cfg.raw_link = link.to_string();
        return Ok(cfg);
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
        let mut cfg = ConfigItem::default();
        cfg.protocol = "CSQTT".into();
        cfg.peer = peer.clone();
        cfg.password = password;
        cfg.name = peer;
        cfg.raw_link = link.to_string();
        return Ok(cfg);
    }

    Err(anyhow!(
        "csqtt:// not connect? and not user:pass@host — got {} chars",
        rest.chars().count()
    ))
}

fn parse_tots(link: &str) -> Result<ConfigItem> {
    let parsed = crate::protocol::parse_tots_uri(link)?;
    let mut cfg = ConfigItem::default();
    cfg.protocol = "ToTS".into();
    cfg.peer = parsed.peer.clone();
    cfg.password = parsed.password;
    cfg.name = format!("ToTS · {}", parsed.peer);
    cfg.raw_link = link.trim().to_string();
    Ok(cfg)
}

fn parse_generic(link: &str, protocol: &str, prefix: &str) -> Result<ConfigItem> {
    log::info!("[PARSE][{}] {}", protocol, short_link(link));
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

    let mut cfg = ConfigItem::default();
    cfg.protocol = protocol.into();
    cfg.peer = peer;
    cfg.password = password;
    cfg.hashes = hashes;
    cfg.name = name;
    cfg.raw_link = link.to_string();
    Ok(cfg)
}

#[cfg(test)]
mod csqtt_219_plain_link_tests {
    use super::parse_link_for_protocol;

    #[test]
    fn csqtt_219_plain_link_skips_encrypted_link_parser() {
        let link = "csqtt://connect?v=2&host=127.0.0.1&peer=46000&password=secret&hashes=h1+h2";
        let config = parse_link_for_protocol(link, "CSQTT 2.1.9").expect("plain link parses");

        assert_eq!(config.protocol, "CSQTT 2.1.9");
        assert_eq!(config.peer, "127.0.0.1:46000");
        assert_eq!(config.password, "secret");
        assert_eq!(config.hashes, "h1,h2");
        assert_eq!(config.raw_link, link);
    }

    #[test]
    fn csqttr_keeps_selected_protocol_after_csqtt_link_parse() {
        let link = "csqtt://connect?v=2&host=127.0.0.1&peer=46000&password=secret&hashes=h1+h2";
        let config = parse_link_for_protocol(link, "CSQTTR").expect("CSQTTR profile parses");

        assert_eq!(config.protocol, "CSQTTR");
        assert_eq!(config.peer, "127.0.0.1:46000");
        assert_eq!(config.raw_link, link);
    }

    #[test]
    fn csqtt_251_keeps_existing_parser_selection() {
        let link = "csqtt://connect?v=2&host=127.0.0.1&peer=46000&password=secret&hashes=h1+h2";
        let config = parse_link_for_protocol(link, "CSQTT 2.5.1").expect("native fallback parses");

        assert_eq!(config.protocol, "CSQTT 2.5.1");
        assert_eq!(config.peer, "127.0.0.1:46000");
    }
}
