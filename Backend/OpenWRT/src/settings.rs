// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Настройки OpenWRT. Device ID хранится отдельно и прокидывается через API.

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
    pub auto_workers: bool,
    pub auto_api_workers: i32,


    // -------- WDTToR (WDTT) --------
    /// Число сессий-воркеров (кратно 9).
    pub wdtt_workers: i32,
    /// Режим обфускации: audio или video.
    pub wdtt_obfs: String,
    /// Как получать хеши: manual (из конфига) или autoApi (VK API).
    pub wdtt_vk_auth_mode: String,
    /// Локальный порт WireGuard-эндпоинта.
    pub wdtt_local_port: i32,
    /// Переопределение device id.
    pub wdtt_device_id: String,

    // -------- Экспериментальное --------
    pub enable_smart_tunnel: bool,
    pub show_core_logs: bool,
    pub share_vpn: bool,
    /// Desktop UI compatibility: this flag is acted on only by the desktop backend,
    /// but OpenWRT persists it so switching API targets does not reset the toggle.
    #[serde(rename = "desktopSocks5Mode")]
    pub desktop_socks5_mode: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            wdtt_workers: 9,
            wdtt_obfs: "audio".into(),
            wdtt_vk_auth_mode: "manual".into(),
            wdtt_local_port: 9000,
            wdtt_device_id: String::new(),
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
            auto_workers: false,
            auto_api_workers: DEFAULT_AUTO_API_WORKERS,


            enable_smart_tunnel: false,
            show_core_logs: false,
            share_vpn: false,
            desktop_socks5_mode: false,
        }
    }
}

impl Settings {
    pub fn normalize(&mut self) {
        if self.workers < MIN_WORKERS { self.workers = MIN_WORKERS; }
        if self.workers > MAX_WORKERS { self.workers = MAX_WORKERS; }

        // WDTToR: воркеры кратны 9 (одна группа), обфускация audio/video.
        self.wdtt_workers = self.wdtt_workers.clamp(9, 108);
        self.wdtt_workers = (self.wdtt_workers / 9) * 9;
        if self.wdtt_workers < 9 { self.wdtt_workers = 9; }
        if !matches!(self.wdtt_obfs.as_str(), "audio" | "video") {
            self.wdtt_obfs = "audio".into();
        }
        if self.wdtt_vk_auth_mode != "autoApi" {
            self.wdtt_vk_auth_mode = "manual".into();
        }
        self.wdtt_local_port = self.wdtt_local_port.clamp(1024, 65535);
        self.wdtt_device_id = self.wdtt_device_id.trim().to_string();

        if self.auto_api_workers < MIN_AUTO_API_WORKERS { self.auto_api_workers = MIN_AUTO_API_WORKERS; }
        if self.auto_api_workers > MAX_AUTO_API_WORKERS { self.auto_api_workers = MAX_AUTO_API_WORKERS; }

        if !matches!(self.auth_mode.as_str(), "manual" | "autoApi" | "autoVk" | "externalHashes") { self.auth_mode = "manual".into(); }
        self.external_hashes_url = self.external_hashes_url.trim().to_string();
        if self.turn_transport.is_empty() { self.turn_transport = "udp".into(); }
        if self.obfs.is_empty() { self.obfs = "video".into(); }
        if self.fingerprint.is_empty() { self.fingerprint = "firefox".into(); }
        if self.captcha_mode.is_empty() { self.captcha_mode = "auto".into(); }
        if self.vk_auth_mode.is_empty() { self.vk_auth_mode = "vkcalls".into(); }
        if self.client_ids.is_empty() { self.client_ids = "8202606,6287487".into(); }

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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn auto_workers_is_opt_in_and_does_not_overwrite_manual_workers() {
        let mut settings: Settings = serde_json::from_value(json!({"workers": 37})).unwrap();
        assert_eq!(settings.get_field("autoWorkers"), Some(json!(false)));
        settings.merge_from_json(json!({"autoWorkers": true})).unwrap();
        let serialized = serde_json::to_value(settings).unwrap();
        assert_eq!(serialized["autoWorkers"], true);
        assert_eq!(serialized["workers"], 37);
        let mut reloaded: Settings = serde_json::from_value(serialized).unwrap();
        reloaded.set_field("autoWorkers", json!(false)).unwrap();
        assert!(!reloaded.auto_workers);
        assert_eq!(reloaded.workers, 37);
    }
}
