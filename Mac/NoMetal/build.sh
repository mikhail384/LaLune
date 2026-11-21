#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FLUTTER="${FLUTTER:-flutter}"
if ! "$FLUTTER" --version | head -1 | grep -q 'Flutter 3\.24\.5 '; then
  echo 'Требуется Flutter 3.24.5; задайте путь через FLUTTER.' >&2; exit 1
fi
for tool in cargo swiftc curl unzip patch shasum; do command -v "$tool" >/dev/null || { echo "Не найден $tool" >&2; exit 1; }; done
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lalune-nometal.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
REV=412d9b37548a269690dffd214d4218195158516e
curl --retry 4 --retry-delay 2 --fail --location --silent --show-error "https://codeload.github.com/mikhail384/LaLune/zip/$REV" -o "$TEMP_DIR/source.zip"
unzip -q "$TEMP_DIR/source.zip" -d "$TEMP_DIR"
SOURCE="$TEMP_DIR/LaLune-$REV"
(cd "$SOURCE/Backend/Desktop" && patch -s -p1 < "$ROOT/Mac/NoMetal/patches/backend.patch" && cargo build --locked)
FRONT="$SOURCE/Frontend"
(cd "$FRONT" && patch -s -p1 < "$ROOT/Mac/NoMetal/patches/frontend.patch")
cp "$ROOT/Mac/NoMetal/pubspec.yaml" "$FRONT/pubspec.yaml"
mkdir -p "$FRONT/dartssh2-local" "$FRONT/assets" "$FRONT/web"
curl --retry 4 --retry-delay 2 --fail --location --silent --show-error https://pub.dev/api/archives/dartssh2-4.1.0.tar.gz -o "$TEMP_DIR/dartssh2.tar.gz"
printf '%s  %s\n' 39359aceafcf5940b868249e3c9c6d86e4e0f989eec7417d033c943157c84c51 "$TEMP_DIR/dartssh2.tar.gz" | shasum -a 256 -c -
tar -xzf "$TEMP_DIR/dartssh2.tar.gz" -C "$FRONT/dartssh2-local"
sed -i '' 's/meta: \^1.16.0/meta: ^1.15.0/' "$FRONT/dartssh2-local/pubspec.yaml"
cp -R "$SOURCE/Assets/." "$FRONT/assets/"
cat > "$FRONT/web/index.html" <<'HTML'
<!DOCTYPE html><html><head><base href="/"><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>LaLune</title></head><body><script src="flutter_bootstrap.js" async></script><script src="glass.js"></script></body></html>
HTML
(cd "$FRONT" && "$FLUTTER" build web --release --web-renderer html --no-tree-shake-icons)
cp "$ROOT/Mac/NoMetal/glass.js" "$FRONT/build/web/glass.js"
swiftc "$ROOT/Mac/NoMetal/blur.swift" -o "$TEMP_DIR/blur"
"$TEMP_DIR/blur" "$SOURCE/Assets/background.png" "$FRONT/build/web/assets/assets/background-blurred.png"
APP="$ROOT/Output/LaLune-NoMetal.app"
if [ -e "$APP" ]; then echo "Уже существует $APP; переместите его перед сборкой." >&2; exit 1; fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -R "$FRONT/build/web" "$APP/Contents/Resources/web"
cp "$ROOT/Mac/NoMetal/proxy.py" "$APP/Contents/Resources/proxy.py"
cp "$SOURCE/Backend/Desktop/target/debug/lalune-backend" "$APP/Contents/Resources/lalune-backend"
swiftc "$ROOT/Mac/NoMetal/webkit-launcher.swift" -swift-version 5 -o "$APP/Contents/MacOS/LaLune"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>LaLune</string><key>CFBundleIdentifier</key><string>local.lalune.webkit</string><key>CFBundleName</key><string>LaLune</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>1</string><key>NSHighResolutionCapable</key><true/></dict></plist>
PLIST
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Готово: $APP"
