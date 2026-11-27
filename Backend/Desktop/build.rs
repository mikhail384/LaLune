// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Build script: stamps the release version and decides whether the Go VK
// token fetcher is embedded.
//
// `Core/TokenFetcher/build.sh` (and the CI) place the gzip-compressed binaries
// in `assets/`. When the file for the current target OS is present we enable
// `has_embedded_token_fetcher`, and `src/vk.rs` links it with `include_bytes!`.
// Without the asset (a plain `cargo build` in a fresh checkout) the cfg stays
// off and the backend falls back to downloading the legacy script.

use std::path::Path;

fn main() {
    let version = std::env::var("LALUNE_VERSION")
        .unwrap_or_else(|_| env!("CARGO_PKG_VERSION").to_string());
    println!("cargo:rustc-env=LALUNE_VERSION={version}");
    println!("cargo:rerun-if-env-changed=LALUNE_VERSION");

    println!("cargo:rerun-if-changed=assets");
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    let asset = match target_os.as_str() {
        "windows" => Some("assets/token-fetcher-windows-amd64.exe.gz"),
        "linux" => Some("assets/token-fetcher-linux-amd64.gz"),
        // macOS/iOS use the in-app WebView fetcher, so nothing to embed.
        _ => None,
    };
    if let Some(asset) = asset {
        if Path::new(asset).exists() {
            println!("cargo:rustc-cfg=has_embedded_token_fetcher");
            println!("cargo:rerun-if-changed={asset}");
        } else {
            println!(
                "cargo:warning=VK token fetcher is not embedded ({asset} missing); \
                 run Core/TokenFetcher/build.sh to build it"
            );
        }
    }
}
