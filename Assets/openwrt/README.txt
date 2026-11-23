This directory is intentionally tracked.
Frontend/pubspec.yaml declares assets/openwrt/ because OpenWRT installer fallback
can load prebundled router binaries from this path. Release builds normally fetch
those binaries from GitHub first; this file keeps the asset directory valid even
when no OpenWRT binaries are embedded in a source checkout.
