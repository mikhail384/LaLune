#!/bin/sh
# Копирует канонические исходники iOS-бэкенда из Backend/iOS в Runner.
#
# В репозитории хранятся только Runner-специфичные AppDelegate.swift и
# SceneDelegate.swift; всё остальное генерируется этим скриптом (и тем же
# списком файлов в .github/workflows/build-ios.yml).
set -eu

cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"
SRC="$ROOT/Backend/iOS"
DST="Runner"

mkdir -p "$DST"

for source in \
  Backend.swift HttpServer.swift CoreManager.swift VkWebViewController.swift \
  TunnelSession.swift TunnelTypes.swift PacketCodec.swift \
  TcpStack.swift UdpNat.swift DnsMessage.swift TunnelResolver.swift \
  PacketPump.swift TunnelSocks5Server.swift Ipv4Routing.swift \
  IncyConfig.swift CallKeepAlive.swift; do
  cp "$SRC/$source" "$DST/$source"
done

cp "$SRC/LaLuneCoreBridge.h" "$DST/LaLuneCoreBridge.h"

echo "iOS backend sources copied to Frontend/ios/Runner"
