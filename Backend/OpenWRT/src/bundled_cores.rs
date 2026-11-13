// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

use anyhow::{bail, Context, Result};
use std::fs::OpenOptions;
use std::io::{self, Cursor};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

include!(concat!(env!("OUT_DIR"), "/bundled_cores.rs"));
const MAX_CORE_SIZE: u64 = 64 * 1024 * 1024;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Core {
    Csqtt,
    Csqttr,
    Legacy,
}

impl Core {
    pub const ALL: [Self; 3] = [Self::Csqtt, Self::Csqttr, Self::Legacy];

    pub fn parse(id: &str) -> Option<Self> {
        match id.trim().to_ascii_uppercase().as_str() {
            "CSQTT" | "CSQTT 2.5.1" => Some(Self::Csqtt),
            "CSQTTR" | "CSQTTR 2.5.2" => Some(Self::Csqttr),
            "CSQTT 2.1.9" => Some(Self::Legacy),
            _ => None,
        }
    }

    pub fn supported(id: &str) -> Option<Self> {
        Self::parse(id).filter(|core| *core == Self::Csqtt || available())
    }

    pub fn id(self) -> &'static str {
        match self {
            Self::Csqtt => "CSQTT",
            Self::Csqttr => "CSQTTR",
            Self::Legacy => "CSQTT 2.1.9",
        }
    }

    pub fn filename(self) -> &'static str {
        match self {
            Self::Csqtt => "csqtt-client",
            Self::Csqttr => "csqttr-client",
            Self::Legacy => "csqtt-219",
        }
    }

    pub fn password_env(self) -> bool {
        self == Self::Csqttr || (self == Self::Csqtt && available())
    }
}

/// Каталог, куда приложение заливает ядра для лёгкой сборки без вшитого архива.
pub const LEAN_DIR: &str = "/usr/lib/lalune-run";

pub fn available() -> bool {
    BUNDLE.is_some()
        || Core::ALL
            .iter()
            .any(|core| Path::new(LEAN_DIR).join(core.filename()).is_file())
}

pub struct TemporaryCore(PathBuf, bool);

impl TemporaryCore {
    pub fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TemporaryCore {
    fn drop(&mut self) {
        // Ядро, лежащее в постоянном кэше на флеше, не удаляем: оно переиспользуется.
        if !self.1 {
            let _ = std::fs::remove_file(&self.0);
        }
    }
}

/// Каталог постоянного кэша ядра на флеше. Он общий с linux_core: оттуда ядро запускается
/// без второй копии в /tmp (каталог читаемый всем, чтобы ядро под отдельным UID могло стартовать).
fn persistent_dir() -> Option<PathBuf> {
    Some(PathBuf::from("/usr/lib/lalune-run"))
}
/// На роутерах с малой ОЗУ `/tmp` — это tmpfs, то есть сама память. Ядро в 10+ МБ там
/// съедало почти всё и приводило к OOM, поэтому при малой памяти кладём ядро на флеш
/// (один раз) и переиспользуем.
fn use_flash_cache() -> bool {
    std::fs::read_to_string("/proc/meminfo")
        .ok()
        .and_then(|text| {
            text.lines()
                .find(|l| l.starts_with("MemTotal:"))
                .and_then(|l| l.split_whitespace().nth(1))
                .and_then(|kb| kb.parse::<u64>().ok())
        })
        .is_some_and(|kb| kb < 192 * 1024)
}

pub async fn extract(core: Core) -> Result<Option<TemporaryCore>> {
    let Some(bytes) = BUNDLE else {
        // Лёгкая сборка: ядро уже лежит на флеше, запускаем прямо оттуда.
        let path = Path::new(LEAN_DIR).join(core.filename());
        return Ok(path.is_file().then(|| TemporaryCore(path, true)));
    };
    tokio::task::spawn_blocking(move || {
        if use_flash_cache() {
            if let Some(dir) = persistent_dir() {
                std::fs::create_dir_all(&dir)?;
                let target = dir.join(core.filename());
                let expected = {
                    let mut archive = zip::ZipArchive::new(Cursor::new(bytes))
                        .context("Архив встроенных OpenWRT-ядер")?;
                    let size = archive.by_name(core.filename())
                        .context("Ядро отсутствует в архиве")?.size();
                    size
                };
                if std::fs::metadata(&target).map(|m| m.len() == expected).unwrap_or(false) {
                    return Ok(Some(TemporaryCore(target, true)));
                }
                // Пишем во временный файл рядом и переименовываем: недокачанного ядра не будет.
                let part = dir.join(format!("{}.part", core.filename()));
                let _ = std::fs::remove_file(&part);
                let mut file = OpenOptions::new().write(true).create(true).truncate(true)
                    .mode(0o755).open(&part)?;
                copy_core(bytes, core, &mut file)?;
                drop(file);
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(&part, std::fs::Permissions::from_mode(0o755))?;
                std::fs::rename(&part, &target)?;
                return Ok(Some(TemporaryCore(target, true)));
            }
        }
        let path = std::env::temp_dir().join(format!("lalune-bundle-{}", uuid::Uuid::new_v4()));
        let mut file = OpenOptions::new().write(true).create_new(true).mode(0o600).open(&path)?;
        let temp = TemporaryCore(path, false);
        copy_core(bytes, core, &mut file)?;
        Ok(Some(temp))
    }).await?
}
fn copy_core(bytes: &[u8], core: Core, output: &mut impl io::Write) -> Result<()> {
    let mut archive = zip::ZipArchive::new(Cursor::new(bytes)).context("Архив встроенных OpenWRT-ядер")?;
    let entry = archive.by_name(core.filename()).context("Ядро отсутствует в архиве")?;
    let size = entry.size();
    if entry.is_dir() || size == 0 || size > MAX_CORE_SIZE {
        bail!("Некорректный размер встроенного ядра");
    }
    if io::copy(&mut io::Read::take(entry, size + 1), output)? != size {
        bail!("Неполное встроенное ядро");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn bundle_selects_exact_core_and_rejects_bad_zip() {
        let mut zip = zip::ZipWriter::new(Cursor::new(Vec::new()));
        for core in Core::ALL {
            zip.start_file(core.filename(), zip::write::SimpleFileOptions::default()
                .compression_method(zip::CompressionMethod::Deflated)
                .compression_level(Some(9))).unwrap();
            zip.write_all(core.id().as_bytes()).unwrap();
        }
        let bytes = zip.finish().unwrap().into_inner();
        for core in Core::ALL {
            let mut result = Vec::new();
            copy_core(&bytes, core, &mut result).unwrap();
            assert_eq!(result, core.id().as_bytes());
        }
        assert!(copy_core(b"bad zip", Core::Csqtt, &mut Vec::new()).is_err());
        assert!(Core::parse("../core").is_none());
        assert!(Core::parse("PaperFlux").is_none());
    }
}
