// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Настройки: Device ID передаётся только ядру CSQTT 2.1.9.

use serde::{Deserialize, Serialize};

pub const DEFAULT_WORKERS: i32 = 9;
pub const MIN_WORKERS: i32 = 1;
pub const MAX_WORKERS: i32 = 127;
pub const DEFAULT_AUTO_API_WORKERS: i32 = 9;
pub const MIN_AUTO_API_WORKERS: i32 = 9;
pub const MAX_AUTO_API_WORKERS: i32 = 27;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Settings {
    // -------- CSQTT --------
    pub peer: String,
    pub vk_hashes: String,
    pub vk_js_token: String,
    pub device_id: String,
    pub password: String,
    pub obfs: String,
    pub fingerprint: String,
    pub client_ids: String,
    pub auth_mode: String,
    pub external_hashes_url: String,
    pub turn_transport: String,
    pub turn_host: String,
    pub turn_port: String,
    pub captcha_mode: String,
    pub vk_auth_mode: String,
    pub allow_hash_redistribution: bool,
    pub validate_vk_hashes: bool,

    // -------- Общие --------
    pub workers: i32,
    pub auto_api_workers: i32,

    // -------- ToTS --------
    pub tots_workers: i32,
    pub tots_mtu: i32,
    pub tots_relay_only: bool,
    pub tots_vk_enabled: bool,
    pub tots_jazz_enabled: bool,
    pub tots_ya_docs_enabled: bool,
    pub tots_mail_docs_enabled: bool,
    pub tots_cups_enabled: bool,
    pub tots_vk_percent: i32,
    pub tots_jazz_percent: i32,
    pub tots_ya_docs_percent: i32,
    pub tots_mail_docs_percent: i32,
    pub tots_cups_percent: i32,
    pub tots_vk_auth_mode: String,
    pub tots_vk_call_links: String,
    pub tots_jazz_room_name: String,
    pub tots_jazz_random_name: bool,
    pub tots_jazz_data: String,
    pub tots_ya_docs_data: String,
    pub tots_mail_docs_data: String,
    pub tots_cups_data: String,


    // -------- Экспериментальное --------
    pub enable_smart_tunnel: bool,
    pub show_core_logs: bool,
    pub share_vpn: bool,
    /// Desktop-only: expose a SOCKS5 endpoint backed by the CSQTT/CSQTTR raw-IP UDP tunnel.
    #[serde(rename = "desktopSocks5Mode")]
    pub desktop_socks5_mode: bool,

    // -------- Split tunneling (Desktop) --------
    /// blacklist: listed IPv4/CIDR destinations bypass VPN.
    /// whitelist is preserved for API compatibility; desktop currently only applies blacklist.
    pub ip_routing_mode: String,
    pub ip_routing_ips: String,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            peer: String::new(),
            vk_hashes: String::new(),
            vk_js_token: String::new(),
            device_id: String::new(),
            password: String::new(),
            obfs: "video".into(),
            fingerprint: "firefox".into(),
            client_ids: "8202606,6287487".into(),
            auth_mode: "manual".into(),
            external_hashes_url: String::new(),
            turn_transport: "udp".into(),
            turn_host: String::new(),
            turn_port: String::new(),
            captcha_mode: "auto".into(),
            vk_auth_mode: "vkcalls".into(),
            allow_hash_redistribution: false,
            validate_vk_hashes: false,

            workers: DEFAULT_WORKERS,
            auto_api_workers: DEFAULT_AUTO_API_WORKERS,

            tots_workers: 1,
            tots_mtu: 1200,
            tots_relay_only: false,
            tots_vk_enabled: true,
            tots_jazz_enabled: true,
            tots_ya_docs_enabled: true,
            tots_mail_docs_enabled: true,
            tots_cups_enabled: true,
            tots_vk_percent: 100,
            tots_jazz_percent: 0,
            tots_ya_docs_percent: 0,
            tots_mail_docs_percent: 0,
            tots_cups_percent: 0,
            tots_vk_auth_mode: "manual".into(),
            tots_vk_call_links: String::new(),
            tots_jazz_room_name: String::new(),
            tots_jazz_random_name: true,
            tots_jazz_data: String::new(),
            tots_ya_docs_data: String::new(),
            tots_mail_docs_data: String::new(),
            tots_cups_data: String::new(),


            enable_smart_tunnel: false,
            show_core_logs: false,
            share_vpn: false,
            desktop_socks5_mode: false,
            ip_routing_mode: "blacklist".into(),
            ip_routing_ips: String::new(),
        }
    }
}

impl Settings {
    pub fn normalize(&mut self) {
        if self.workers < MIN_WORKERS { self.workers = MIN_WORKERS; }
        if self.workers > MAX_WORKERS { self.workers = MAX_WORKERS; }

        if self.auto_api_workers < MIN_AUTO_API_WORKERS { self.auto_api_workers = MIN_AUTO_API_WORKERS; }
        if self.auto_api_workers > MAX_AUTO_API_WORKERS { self.auto_api_workers = MAX_AUTO_API_WORKERS; }
        self.tots_workers = self.tots_workers.clamp(1, 256);
        self.tots_mtu = self.tots_mtu.clamp(576, 1400);
        self.tots_vk_percent = self.tots_vk_percent.clamp(0, 100);
        self.tots_jazz_percent = self.tots_jazz_percent.clamp(0, 100);
        self.tots_ya_docs_percent = self.tots_ya_docs_percent.clamp(0, 100);
        self.tots_mail_docs_percent = self.tots_mail_docs_percent.clamp(0, 100);
        self.tots_cups_percent = self.tots_cups_percent.clamp(0, 100);
        if self.tots_vk_auth_mode != "autoApi" { self.tots_vk_auth_mode = "manual".into(); }

        if !matches!(self.auth_mode.as_str(), "manual" | "autoApi" | "autoVk" | "externalHashes") { self.auth_mode = "manual".into(); }
        self.external_hashes_url = self.external_hashes_url.trim().to_string();
        if self.turn_transport.is_empty() { self.turn_transport = "udp".into(); }
        if self.obfs.is_empty() { self.obfs = "video".into(); }
        if self.fingerprint.is_empty() { self.fingerprint = "firefox".into(); }
        if self.captcha_mode.is_empty() { self.captcha_mode = "auto".into(); }
        if self.vk_auth_mode.is_empty() { self.vk_auth_mode = "vkcalls".into(); }
        if self.client_ids.is_empty() { self.client_ids = "8202606,6287487".into(); }


        if self.ip_routing_mode != "whitelist" {
            self.ip_routing_mode = "blacklist".into();
        }
    }

    pub fn merge_from_json(&mut self, value: serde_json::Value) -> anyhow::Result<()> {
        let mut base = serde_json::to_value(&*self)?;
        if let (Some(base_obj), Some(patch_obj)) = (base.as_object_mut(), value.as_object()) {
            for (k, v) in patch_obj {
                base_obj.insert(k.clone(), v.clone());
            }
        }
        let merged: Settings = serde_json::from_value(base)?;
        *self = merged;
        self.normalize();
        Ok(())
    }

    pub fn get_field(&self, key: &str) -> Option<serde_json::Value> {
        let v = serde_json::to_value(self).ok()?;
        v.get(key).cloned()
    }

    pub fn set_field(&mut self, key: &str, value: serde_json::Value) -> anyhow::Result<()> {
        let mut v = serde_json::to_value(&*self)?;
        if let Some(obj) = v.as_object_mut() {
            obj.insert(key.to_string(), value);
        }
        let new_settings: Settings = serde_json::from_value(v)?;
        *self = new_settings;
        self.normalize();
        Ok(())
    }
}
