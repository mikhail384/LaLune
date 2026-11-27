// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// VK: получение токена (встроенный Go-фетчер), валидация, auto-calls.

use anyhow::{anyhow, Context, Result};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;
use tokio::process::Command;

use crate::events::{Event, EventBus};

pub const VK_API_BASE: &str = "https://api.vk.ru/method/";
pub const VK_API_VERSION: &str = "5.199";

pub const VK_CLIENT_ID: &str = "7793118";
pub const VK_SCOPE: &str = "1073737727";
pub const VK_REDIRECT_URI: &str = "https://oauth.vk.ru/blank.html";

/// Legacy fallback scripts, used only when the embedded fetcher is missing
/// (a `cargo build` in a checkout that never ran `Core/TokenFetcher/build.sh`).
pub const TOKEN_PS1_URL: &str =
    "https://raw.githubusercontent.com/Endlad2/LaLune/refs/heads/main/Token.ps1";
pub const TOKEN_SH_URL: &str =
    "https://raw.githubusercontent.com/Endlad2/LaLune/refs/heads/main/Token.sh";

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VkTokenState {
    pub has_token: bool,
    pub fetching: bool,
    pub progress: i32,
    pub message: String,
}

impl Default for VkTokenState {
    fn default() -> Self {
        Self {
            has_token: false,
            fetching: false,
            progress: 0,
            message: String::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VkLoginResponse {
    pub ok: bool,
    pub needs_ui: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub auth_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

/// Строит URL страницы авторизации VK (для мобильных платформ).
pub fn auth_url() -> String {
    format!(
        "https://oauth.vk.ru/authorize?client_id={}&scope={}&redirect_uri={}&display=page&response_type=token&revoke=1&v=5.199",
        VK_CLIENT_ID,
        VK_SCOPE,
        urlencode(VK_REDIRECT_URI)
    )
}

fn urlencode(s: &str) -> String {
    s.replace(':', "%3A").replace('/', "%2F")
}

/// Читает token.json из appDir. Поддерживает "Token" и "token".
pub fn read_token(app_dir: &PathBuf) -> Option<String> {
    let path = app_dir.join("token.json");
    let data = std::fs::read_to_string(&path).ok()?;
    let v: serde_json::Value = serde_json::from_str(&data).ok()?;

    if let Some(t) = v.get("Token").and_then(|x| x.as_str()) {
        if !t.trim().is_empty() {
            return Some(t.trim().to_string());
        }
    }
    if let Some(t) = v.get("token").and_then(|x| x.as_str()) {
        if !t.trim().is_empty() {
            return Some(t.trim().to_string());
        }
    }
    None
}

/// Сохраняет токен в token.json.
pub fn save_token(app_dir: &PathBuf, token: &str) -> Result<()> {
    let path = app_dir.join("token.json");
    let payload = serde_json::json!({
        "Token": token,
        "SavedAt": chrono::Utc::now().to_rfc3339(),
    });
    std::fs::write(path, serde_json::to_string_pretty(&payload)?)?;
    Ok(())
}

pub fn delete_token(app_dir: &PathBuf) -> Result<()> {
    let path = app_dir.join("token.json");
    if path.exists() {
        std::fs::remove_file(path)?;
    }
    Ok(())
}

pub fn token_state(app_dir: &PathBuf) -> VkTokenState {
    let has = read_token(app_dir).is_some();
    VkTokenState {
        has_token: has,
        fetching: false,
        progress: if has { 100 } else { 0 },
        message: if has {
            "VK token active".into()
        } else {
            String::new()
        },
    }
}

/// Embedded Go token fetcher (gzip-compressed), linked by `build.rs`.
///
/// The backend ships the fetcher inside its own binary: on login it is
/// unpacked into `<appDir>/token-fetcher/` and executed. It installs the
/// Playwright Chromium itself when the machine does not have one yet.
#[cfg(all(has_embedded_token_fetcher, target_os = "windows"))]
const EMBEDDED_TOKEN_FETCHER: &[u8] =
    include_bytes!("../assets/token-fetcher-windows-amd64.exe.gz");
#[cfg(all(has_embedded_token_fetcher, target_os = "linux"))]
const EMBEDDED_TOKEN_FETCHER: &[u8] = include_bytes!("../assets/token-fetcher-linux-amd64.gz");

/// Directory (relative to appDir) where the unpacked fetcher lives.
const FETCHER_DIR: &str = "token-fetcher";

fn fetcher_file_name() -> &'static str {
    if cfg!(target_os = "windows") {
        "token-fetcher.exe"
    } else {
        "token-fetcher"
    }
}

/// Writes the embedded fetcher next to the token file and returns its path.
///
/// The file is rewritten on every login: it is small, and a stale binary from
/// an older app version must never be executed.
#[cfg(all(has_embedded_token_fetcher, any(target_os = "windows", target_os = "linux")))]
fn extract_embedded_fetcher(app_dir: &Path) -> Result<PathBuf> {
    let dir = app_dir.join(FETCHER_DIR);
    std::fs::create_dir_all(&dir)
        .with_context(|| format!("cannot create {}", dir.display()))?;
    let path = dir.join(fetcher_file_name());

    let mut decoder = flate2::read::GzDecoder::new(EMBEDDED_TOKEN_FETCHER);
    let mut binary = Vec::new();
    decoder
        .read_to_end(&mut binary)
        .context("embedded token fetcher is corrupted")?;
    if binary.len() < 1024 {
        return Err(anyhow!("embedded token fetcher is truncated"));
    }

    // Write through a temporary file so a half-written binary is never run.
    let staging = dir.join(format!("{}.tmp", fetcher_file_name()));
    std::fs::write(&staging, &binary)
        .with_context(|| format!("cannot write {}", staging.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = std::fs::metadata(&staging)?.permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&staging, perms)?;
    }
    std::fs::rename(&staging, &path)
        .with_context(|| format!("cannot install {}", path.display()))?;
    Ok(path)
}

/// Launches the token fetcher in a detached process.
///
/// The fetcher opens a browser window and may take minutes, so this returns as
/// soon as the process is spawned; the UI polls `/vk/token/state`.
pub async fn launch_token_fetcher(app_dir: &PathBuf, events: EventBus) -> Result<()> {
    let token_path = app_dir.join("token.json");

    #[cfg(all(has_embedded_token_fetcher, any(target_os = "windows", target_os = "linux")))]
    {
        let binary = extract_embedded_fetcher(app_dir)?;
        let log_path = app_dir.join("token-fetcher.log");
        let stdout = std::fs::File::create(&log_path)
            .with_context(|| format!("cannot create {}", log_path.display()))?;
        let stderr = stdout.try_clone()?;

        let mut command = Command::new(&binary);
        command
            .arg("--token-path")
            .arg(&token_path)
            .stdin(Stdio::null())
            .stdout(Stdio::from(stdout))
            .stderr(Stdio::from(stderr));

        #[cfg(target_os = "windows")]
        {
            // DETACHED_PROCESS: the fetcher owns its browser window, and we do
            // not want a console attached to the backend's process.
            // `tokio::process::Command::creation_flags` is inherent on Windows.
            const DETACHED_PROCESS: u32 = 0x0000_0008;
            command.creation_flags(DETACHED_PROCESS);
        }

        let child = command
            .spawn()
            .with_context(|| format!("cannot start {}", binary.display()))?;
        events.emit(Event::log(format!(
            "[VK] token fetcher started (pid {}), log: {}",
            child.id().unwrap_or(0),
            log_path.display()
        )));
        return Ok(());
    }

    #[cfg(all(not(has_embedded_token_fetcher), target_os = "windows"))]
    {
        let _ = &token_path;
        let inner = format!(
            "$ErrorActionPreference='Continue'; \
             try {{ irm {} | iex }} \
             catch {{ Write-Host ('[Token.ps1] ' + $_.Exception.Message) -ForegroundColor Red; \
             Read-Host 'Press Enter to close' }}",
            TOKEN_PS1_URL
        );
        let status = Command::new("cmd")
            .args([
                "/c",
                "start",
                "",
                "powershell",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-Command",
                &inner,
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await?;
        if !status.success() {
            return Err(anyhow!("failed to start PowerShell (exit {:?})", status.code()));
        }
        events.emit(Event::log(
            "[VK] token fetcher is not embedded; launched the legacy Token.ps1",
        ));
        Ok(())
    }

    #[cfg(all(not(has_embedded_token_fetcher), target_os = "linux"))]
    {
        let _ = &token_path;
        let cmd_line = format!("curl -fsSL {} | bash", TOKEN_SH_URL);
        let child = Command::new("bash")
            .args(["-c", &cmd_line])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()?;
        events.emit(Event::log(format!(
            "[VK] token fetcher is not embedded; launched the legacy Token.sh (pid {})",
            child.id().unwrap_or(0)
        )));
        Ok(())
    }

    #[cfg(not(any(target_os = "windows", target_os = "linux")))]
    {
        let _ = (app_dir, events);
        Err(anyhow!("unsupported platform for token fetcher"))
    }
}

// ============================================================
//  VK API client (calls.start / calls.forceFinish)
// ============================================================

pub struct VkApiClient {
    http: Client,
    pub token: String,
}

#[derive(Debug, Default, Clone)]
pub struct VkCallStartResult {
    pub call_id: String,
    pub hash: String,
    pub error_code: i32,
    pub error_message: String,
    pub failed: bool,
}

impl VkCallStartResult {
    pub fn is_success(&self) -> bool {
        !self.call_id.is_empty() && !self.hash.is_empty()
    }
    pub fn token_invalid(&self) -> bool {
        matches!(self.error_code, 4 | 5 | 27 | 28)
    }
}

impl VkApiClient {
    pub fn new(token: String) -> Self {
        let http = Client::builder()
            .timeout(Duration::from_secs(8))
            .build()
            .expect("http client");
        Self { http, token }
    }

    async fn call(
        &self,
        method: &str,
        params: &[(&str, &str)],
    ) -> Result<serde_json::Value> {
        let url = format!("{}{}", VK_API_BASE, method);
        let mut form: Vec<(String, String)> = params
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        form.push(("v".to_string(), VK_API_VERSION.to_string()));

        let resp = self
            .http
            .post(&url)
            .bearer_auth(&self.token)
            .header("Content-Type", "application/x-www-form-urlencoded")
            .header("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
            .header("Accept", "*/*")
            .header("Origin", "https://vk.com")
            .header("Referer", "https://vk.com/")
            .form(&form)
            .send()
            .await?
            .json::<serde_json::Value>()
            .await?;
        Ok(resp)
    }

    pub async fn start_call(&self) -> VkCallStartResult {
        let j = match self.call("calls.start", &[]).await {
            Ok(v) => v,
            Err(e) => {
                return VkCallStartResult {
                    failed: true,
                    error_message: e.to_string(),
                    ..Default::default()
                }
            }
        };

        if let Some(err) = j.get("error") {
            return VkCallStartResult {
                error_code: err
                    .get("error_code")
                    .and_then(|v| v.as_i64())
                    .unwrap_or(0) as i32,
                error_message: err
                    .get("error_msg")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string(),
                failed: true,
                ..Default::default()
            };
        }

        let resp = match j.get("response") {
            Some(r) => r,
            None => {
                return VkCallStartResult {
                    failed: true,
                    error_message: "no response in calls.start".into(),
                    ..Default::default()
                }
            }
        };

        let call_id = resp
            .get("call_id")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let ok_join_link = resp
            .get("ok_join_link")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let join_link = resp
            .get("join_link")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();

        let mut hash = ok_join_link;
        if hash.is_empty() && !join_link.is_empty() {
            if let Some(seg) = join_link.rsplit('/').next() {
                hash = seg.to_string();
            }
        }

        if call_id.is_empty() || hash.is_empty() {
            return VkCallStartResult {
                failed: true,
                error_message: "empty call_id/hash".into(),
                ..Default::default()
            };
        }
        VkCallStartResult {
            call_id,
            hash,
            ..Default::default()
        }
    }

    pub async fn force_finish(&self, call_id: &str) -> bool {
        match self.call("calls.forceFinish", &[("call_id", call_id)]).await {
            Ok(j) => j.get("error").is_none(),
            Err(_) => false,
        }
    }
}

/// Как в Go-версии: ceil(workers / autoApiWorkers), ограничено 1..6.
pub fn call_count_for_workers(workers: i32, auto_api_workers: i32) -> i32 {
    let aw = if auto_api_workers <= 0 {
        crate::settings::DEFAULT_AUTO_API_WORKERS
    } else {
        auto_api_workers
    };
    let w = if workers <= 0 {
        crate::settings::DEFAULT_WORKERS
    } else {
        workers
    };
    let count = ((w as f64) / (aw as f64)).ceil() as i32;
    count.clamp(1, 6)
}

/// Проверяет токен через users.get — возвращает true, если токен валиден.
pub async fn validate_token(token: &str) -> Result<bool> {
    let client = VkApiClient::new(token.to_string());
    let j = client.call("users.get", &[]).await?;
    Ok(j.get("error").is_none())
}

#[cfg(all(test, has_embedded_token_fetcher, any(target_os = "windows", target_os = "linux")))]
mod embedded_fetcher_tests {
    use super::*;

    /// The embedded blob must be a real, runnable executable for this target:
    /// a corrupted or truncated gzip would otherwise only fail at login time.
    #[test]
    fn embedded_fetcher_is_a_valid_executable() {
        let mut decoder = flate2::read::GzDecoder::new(EMBEDDED_TOKEN_FETCHER);
        let mut binary = Vec::new();
        decoder.read_to_end(&mut binary).expect("embedded gzip must decode");
        assert!(binary.len() > 1024, "embedded binary is truncated");

        if cfg!(target_os = "windows") {
            assert_eq!(&binary[..2], b"MZ", "embedded fetcher is not a PE executable");
        } else {
            assert_eq!(&binary[..4], b"\x7fELF", "embedded fetcher is not an ELF binary");
        }
    }

    #[test]
    fn extraction_writes_an_executable_and_never_leaves_a_partial_file() {
        let dir = std::env::temp_dir().join(format!(
            "lalune-fetcher-test-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let path = extract_embedded_fetcher(&dir).expect("extract");
        assert!(path.exists());
        let name = path.file_name().unwrap().to_string_lossy().to_string();
        assert_eq!(name, fetcher_file_name());
        assert!(!dir.join(format!("{}.tmp", name)).exists(), "staging file left behind");

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&path).unwrap().permissions().mode();
            assert_eq!(mode & 0o111, 0o111, "fetcher is not executable");
        }

        // A second extraction overwrites the previous binary.
        let again = extract_embedded_fetcher(&dir).expect("re-extract");
        assert_eq!(again, path);

        let _ = std::fs::remove_dir_all(&dir);
    }
}
