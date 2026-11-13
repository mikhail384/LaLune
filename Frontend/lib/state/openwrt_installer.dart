// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Установка LaLune backend на OpenWRT по SSH.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../api/api_client.dart';

class OpenWrtInstallResult {
  final bool ok;
  final String message;
  final String log;

  const OpenWrtInstallResult({
    required this.ok,
    required this.message,
    this.log = '',
  });
}

class OpenWrtInstaller {
  /// Каталог релиза; конкретный файл (`lalune-openwrt-backend[-<abi>]`)
  /// скрипт выбирает на роутере по DISTRIB_ARCH.
  static const backendBaseUrl =
      'https://github.com/mikhail384/LaLune/releases/latest/download';

  /// Код выхода скрипта: роутер не смог скачать backend, нужна загрузка с телефона.
  static const needUploadExitCode = 28;

  /// Backend для [abi]: сначала скачиваем на телефоне, иначе берём встроенную копию.
  static Future<Uint8List?> _obtainBackend(
    String abi,
    void Function(String message)? onProgress,
  ) async {
    final name =
        abi == 'aarch64' ? 'lalune-openwrt-backend' : 'lalune-openwrt-backend-$abi';
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
      try {
        final request = await client.getUrl(Uri.parse('$backendBaseUrl/$name'));
        final response = await request.close().timeout(const Duration(seconds: 60));
        if (response.statusCode == 200) {
          final builder = BytesBuilder(copy: false);
          await for (final chunk in response.timeout(const Duration(seconds: 60))) {
            builder.add(chunk);
          }
          final data = builder.takeBytes();
          if (data.length > 1000000) return data;
        }
      } finally {
        client.close(force: true);
      }
    } catch (_) {}
    try {
      onProgress?.call('GitHub недоступен с телефона, беру встроенную копию...');
      final data = await rootBundle.load('assets/openwrt/$name');
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (_) {
      return null;
    }
  }

  /// Готовый скрипт установки (используется и в тестах).
  static String installScript() =>
      _installScript.replaceAll('__BACKEND_BASE__', backendBaseUrl);

  static const _algorithms = SSHAlgorithms(
    kex: [
      SSHKexType.x25519Rfc,
      SSHKexType.x25519,
      SSHKexType.nistp521,
      SSHKexType.nistp384,
      SSHKexType.nistp256,
      SSHKexType.dhGexSha256,
      SSHKexType.dh14Sha256,
      // Старые Dropbear/OpenWRT могут предлагать только SHA-1 KEX.
      SSHKexType.dh14Sha1,
      SSHKexType.dhGexSha1,
      SSHKexType.dh1Sha1,
    ],
    hostkey: [
      SSHHostkeyType.ed25519,
      SSHHostkeyType.rsaSha512,
      SSHHostkeyType.rsaSha256,
      SSHHostkeyType.ecdsa521,
      SSHHostkeyType.ecdsa384,
      SSHHostkeyType.ecdsa256,
      SSHHostkeyType.rsaSha1,
    ],
    cipher: [
      SSHCipherType.aes256gcm,
      SSHCipherType.aes128gcm,
      SSHCipherType.chacha20poly1305,
      SSHCipherType.aes256ctr,
      SSHCipherType.aes128ctr,
      // Только как fallback для старых роутеров.
      SSHCipherType.aes256cbc,
      SSHCipherType.aes128cbc,
    ],
  );

  static Future<OpenWrtInstallResult> install({
    required String host,
    required String username,
    required String password,
    void Function(String message)? onProgress,
  }) async {
    SSHClient? client;
    var stage = 'подключение к SSH';
    try {
      onProgress?.call('Подключение к SSH $host:22...');
      final socket = await SSHSocket.connect(
        host,
        22,
        timeout: const Duration(seconds: 5),
      );
      client = SSHClient(
        socket,
        username: username,
        onPasswordRequest: () => password,
        algorithms: _algorithms,
        handshakeTimeout: const Duration(seconds: 12),
        authTimeout: const Duration(seconds: 12),
      );
      await client.authenticated;

      stage = 'выполнение скрипта установки';
      onProgress?.call('Установка backend и зависимостей...');
      final script = installScript();
      var result = await client.runWithResult(script);
      var stdout = utf8.decode(result.stdout, allowMalformed: true);
      var stderr = utf8.decode(result.stderr, allowMalformed: true);
      var combined =
          [stdout.trim(), stderr.trim()].where((s) => s.isNotEmpty).join('\n');

      // Роутер не смог скачать backend (например, GitHub недоступен у провайдера):
      // скачиваем на телефоне (или берём встроенную копию) и загружаем по SSH.
      if (result.exitCode == needUploadExitCode) {
        final abi = RegExp(r'LALUNE_NEED_UPLOAD abi=(\S+)')
            .firstMatch(stderr)
            ?.group(1);
        if (abi == null) {
          return OpenWrtInstallResult(
            ok: false,
            message: 'Роутер не скачал backend, архитектура не определена',
            log: combined,
          );
        }
        onProgress?.call('Роутер не достучался до GitHub. Загружаю backend с телефона...');
        final bytes = await _obtainBackend(abi, onProgress);
        if (bytes == null) {
          return OpenWrtInstallResult(
            ok: false,
            message:
                'Роутер не может скачать backend, а телефон не смог получить файл для $abi. '
                'Подключите телефон к сети, где доступен GitHub (VPN/другая сеть), и повторите.',
            log: combined,
          );
        }
        stage = 'подготовка роутера к загрузке';
        final home = utf8
            .decode((await client.run(r'echo "$HOME"')), allowMalformed: true)
            .trim();
        final dir = (home.isEmpty ? '/root' : home) + '/la-lune';
        onProgress?.call('Передача backend на роутер (${(bytes.length / 1048576).toStringAsFixed(1)} МБ)...');
        await client.run('mkdir -p "$dir"');
        final target = '$dir/lalune-openwrt-backend';

        // Освобождаем ОЗУ: на роутерах с 64 МБ запущенный backend + заливка 20 МБ
        // приводят к тому, что Dropbear рвёт соединение.
        await client.run('/etc/init.d/lalune stop >/dev/null 2>&1; '
            'killall lalune-openwrt-backend >/dev/null 2>&1; '
            'killall csqtt-client >/dev/null 2>&1; sleep 1; '
            'echo 3 > /proc/sys/vm/drop_caches 2>/dev/null; true');

        // Если на роутере уже лежит файл нужного размера (прошлая установка) — не льём заново.
        final existing = utf8
            .decode(await client.run('wc -c < "$target" 2>/dev/null || echo 0'),
                allowMalformed: true)
            .trim();
        if (existing == '${bytes.length}') {
          onProgress?.call('Файл backend на роутере уже актуален, загрузка не нужна');
        } else {
          // Роутеры с 64 МБ ОЗУ не переживают один длинный поток в 20 МБ: буфер записи на
          // флеш раздувает память. Льём порциями по 128 КБ, каждая — отдельным коротким
          // exec с `cat >>`, и периодически делаем sync и сбрасываем кэш.
          await client.run('rm -f "$target.part"');
          stage = 'передача файла';
          const chunk = 128 * 1024;
          var sent = 0;
          var chunkIndex = 0;
          for (var offset = 0; offset < bytes.length; offset += chunk) {
            final end = offset + chunk < bytes.length ? offset + chunk : bytes.length;
            final piece = Uint8List.sublistView(bytes, offset, end);
            final session = await client.execute('cat >> "$target.part"');
            session.stdin.add(piece);
            await session.stdin.close();
            await session.done;
            sent = end;
            chunkIndex++;
            stage = 'передача файла (${sent * 100 ~/ bytes.length}%)';
            if (chunkIndex % 8 == 0) {
              await client.run(
                  'sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null; true');
              onProgress?.call(
                  'Передача backend на роутер: ${(sent * 100 ~/ bytes.length)}%');
            }
          }
          await client.run('sync');
          final size = utf8
              .decode(await client.run('wc -c < "$target.part"'),
                  allowMalformed: true)
              .trim();
          if (size != '${bytes.length}') {
            return OpenWrtInstallResult(
              ok: false,
              message:
                  'Файл передан не полностью ($size из ${bytes.length} байт). Повторите установку.',
              log: combined,
            );
          }
          await client.run('mv -f "$target.part" "$target"');
        }
        stage = 'запуск backend после загрузки';
        onProgress?.call('Установка backend и зависимостей...');
        result = await client.runWithResult('LALUNE_PREUPLOADED=1\n$script');
        stdout = utf8.decode(result.stdout, allowMalformed: true);
        stderr = utf8.decode(result.stderr, allowMalformed: true);
        combined = [combined, stdout.trim(), stderr.trim()]
            .where((s) => s.isNotEmpty)
            .join('\n');
      }

      if (result.exitCode != 0 || !stdout.contains('LALUNE_INSTALL_OK')) {
        return OpenWrtInstallResult(
          ok: false,
          message: 'Установка по SSH завершилась с ошибкой',
          log: combined,
        );
      }

      onProgress?.call('Проверка LaLune API на $host:1062...');
      for (var attempt = 0; attempt < 12; attempt++) {
        final ping = await ApiClient.pingHost(
          host,
          timeout: const Duration(seconds: 2),
        );
        if (ping != null &&
            ping['ok'] == true &&
            (ping['platform'] ?? '').toString().toLowerCase() == 'openwrt') {
          return OpenWrtInstallResult(
            ok: true,
            message: 'Установлено. Теперь выполните соединение с роутером.',
            log: combined,
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }

      return OpenWrtInstallResult(
        ok: false,
        message:
            'Файлы установлены, но API на $host:1062 не ответил. Проверьте лог backend.',
        log: combined,
      );
    } catch (e) {
      return OpenWrtInstallResult(
        ok: false,
        message: 'Не удалось установить OpenWRT backend на шаге «$stage»: $e',
      );
    } finally {
      if (client != null) {
        try {
          await client.close();
        } catch (_) {}
      }
    }
  }

  static const _installScript = r'''
set -eu

BACKEND_BASE="__BACKEND_BASE__"
BACKEND_URL=""
INSTALL_DIR="$HOME/la-lune"
DATA_DIR="$HOME/.la-lune"
BACKEND_PATH="$INSTALL_DIR/lalune-openwrt-backend"
PID_FILE="$DATA_DIR/backend.pid"
LOG_FILE="$DATA_DIR/LaLuneManager.log"

log() { printf '[lalune-install] %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# Сборка backend выбирается по архитектуре пакетов OpenWrt (DISTRIB_ARCH):
# один статический musl-бинарник на архитектуру, а не на SoC.
lalune_abi() {
  case "${1:-}" in
    aarch64_*) echo aarch64 ;;
    x86_64) echo x86_64 ;;
    i386_pentium-mmx) return 1 ;;
    i386_*) echo i386 ;;
    mipsel_mips32|mips_mips32) return 1 ;;
    mipsel_*) echo ramips ;;
    mips_*) echo mips ;;
    arm_cortex-a5*|arm_cortex-a7*|arm_cortex-a8*|arm_cortex-a9*|arm_cortex-a15*|arm_cortex-a17*|arm_cortex-a53*|arm_cortex-a72*|arm_neoverse*) echo armv7 ;;
    arm_*) echo armv5 ;;
    *) return 1 ;;
  esac
}

unset DISTRIB_TARGET DISTRIB_ARCH
[ -r /etc/openwrt_release ] && . /etc/openwrt_release
arch="$(uname -m 2>/dev/null || true)"
abi=""
[ -n "${DISTRIB_ARCH:-}" ] && abi="$(lalune_abi "$DISTRIB_ARCH" || true)"
if [ -z "$abi" ]; then
  case "$arch" in
    aarch64|arm64) abi=aarch64 ;;
    x86_64) abi=x86_64 ;;
    i386|i486|i586|i686) abi=i386 ;;
    armv7*|armv8l) abi=armv7 ;;
    armv5*|armv6*) abi=armv5 ;;
  esac
fi
if [ -z "$abi" ]; then
  echo "Unsupported router architecture: uname=$arch, OpenWrt=${DISTRIB_TARGET:-?} (${DISTRIB_ARCH:-?}). Supported: aarch64, x86_64, i386 (SSE2), mips/mipsel, arm." >&2
  exit 21
fi
case "$abi" in
  aarch64) BACKEND_URL="$BACKEND_BASE/lalune-openwrt-backend" ;;
  *) BACKEND_URL="$BACKEND_BASE/lalune-openwrt-backend-$abi" ;;
esac
log "router: ${DISTRIB_TARGET:-?} (${DISTRIB_ARCH:-$arch}) -> build $abi"

if have id && [ "$(id -u 2>/dev/null || echo 1)" != "0" ]; then
  echo 'OpenWRT backend must be installed as root' >&2
  exit 20
fi

mkdir -p "$INSTALL_DIR" "$DATA_DIR"

PKG_LOG="${TMPDIR:-/tmp}/lalune-pkg.log"
PKG_UPDATED=0

# Ставит пакеты и сохраняет вывод менеджера в $PKG_LOG, чтобы при ошибке было видно причину
# (нет интернета/DNS, пакета нет в фиде, конфликт ip-tiny и т.д.).
install_packages() {
  if have apk; then
    if [ "$PKG_UPDATED" = 0 ]; then apk update >"$PKG_LOG" 2>&1 || true; PKG_UPDATED=1; fi
    apk add "$@" >>"$PKG_LOG" 2>&1
  elif have opkg; then
    if [ "$PKG_UPDATED" = 0 ]; then opkg update >"$PKG_LOG" 2>&1 || true; PKG_UPDATED=1; fi
    opkg install "$@" >>"$PKG_LOG" 2>&1
  else
    echo 'no package manager (apk/opkg)' >"$PKG_LOG"
    return 1
  fi
}

pkg_error_tail() {
  [ -s "$PKG_LOG" ] && tail -n 6 "$PKG_LOG" | sed 's/^/  pkg: /' >&2
  return 0
}

ensure_downloader() {
  if have uclient-fetch || have wget || have curl; then
    return 0
  fi
  log 'download utility missing; installing wget/CA certificates'
  install_packages ca-bundle ca-certificates || true
  install_packages wget-ssl || install_packages wget || true
  have uclient-fetch || have wget || have curl
}

download() {
  url="$1"
  dest="$2"
  tmp="$dest.part"
  rm -f "$tmp"
  if ! (
    if have uclient-fetch; then
      uclient-fetch -q -O "$tmp" "$url"
    elif have wget; then
      wget -q -O "$tmp" "$url"
    elif have curl; then
      curl -fL --retry 3 --connect-timeout 20 --max-time 300 -o "$tmp" "$url"
    else
      exit 1
    fi
  ) || [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    echo "Download failed: $url" >&2
    return 1
  fi
  mv -f "$tmp" "$dest"
}

ensure_downloader || {
  echo 'Could not install/find curl, wget or uclient-fetch' >&2
  exit 22
}

# Для iptables/fwmark policy routing нужен полный iproute2 на обеих архитектурах.
have_route_ip() {
  have ip && { ip -N -4 rule show >/dev/null 2>&1 || ip -4 rule show >/dev/null 2>&1; }
}

if ! have_route_ip; then
  log 'ip utility missing; trying to install ip-full'
  if ! install_packages ip-full; then
    # ip-tiny/busybox-ip конфликтуют с ip-full: убираем и пробуем снова.
    if have opkg && opkg list-installed 2>/dev/null | grep -q '^ip-tiny '; then
      log 'removing ip-tiny (conflicts with ip-full)'
      opkg remove ip-tiny >>"$PKG_LOG" 2>&1 || true
    fi
    install_packages ip-full || true
  fi
fi
if ! have_route_ip; then
  {
    echo 'A compatible ip utility is required for VPN routes (ip-full)'
    echo 'Не удалось установить ip-full: проверьте, что роутер выходит в интернет и DNS работает'
    echo '(на роутере: opkg update && opkg install ip-full), затем повторите установку.'
  } >&2
  {
    echo "ip: $(command -v ip 2>/dev/null || echo 'не найден')"
    ip -4 rule show 2>&1 | head -n 2 | sed 's/^/  ip: /'
  } >&2
  pkg_error_tail
  exit 24
fi

if ! have iptables && ! have iptables-nft; then
  log 'iptables missing; trying to install iptables-nft'
  install_packages iptables-nft || install_packages iptables || true
fi
if ! have iptables && ! have iptables-nft; then
  if have nft; then
    # OpenWrt 25.x на маленьких роутерах: только nftables. Бэкенд умеет работать без iptables.
    log 'iptables not available; will use native nftables for marking/NAT'
  else
    echo 'Neither iptables-nft nor nft is available: VPN marking/NAT is impossible' >&2
    pkg_error_tail
    exit 27
  fi
fi

# NAT для клиентов LAN: без xt_MASQUERADE iptables пишет "Extension MASQUERADE
# revision 0 not supported". Модули ядра ставим по возможности, не фатально.
for pkg in kmod-ipt-nat kmod-nft-nat kmod-nft-compat iptables-mod-nat-extra iptables-mod-extra kmod-ipt-extra; do
  install_packages "$pkg" >/dev/null 2>&1 || true
done

if [ ! -c /dev/net/tun ]; then
  log '/dev/net/tun missing; trying to install/load kmod-tun'
  install_packages kmod-tun || true
  have modprobe && modprobe tun >/dev/null 2>&1 || true
  if [ ! -e /dev/net/tun ] && have mknod; then
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200 >/dev/null 2>&1 || true
    chmod 600 /dev/net/tun >/dev/null 2>&1 || true
  fi
fi
if [ ! -c /dev/net/tun ]; then
  echo '/dev/net/tun is unavailable; install/enable TUN support on this OpenWRT' >&2
  exit 25
fi

if ! have nohup; then
  log 'nohup missing; trying to install coreutils-nohup'
  install_packages coreutils-nohup || true
fi
if ! have nohup; then
  echo 'nohup is required to keep backend running after SSH disconnect' >&2
  exit 26
fi

# В старых опубликованных backend могла использоваться команда `sudo` даже
# при запуске от root. Не меняем систему: даём только этому процессу shim.
COMPAT_BIN="$INSTALL_DIR/bin"
mkdir -p "$COMPAT_BIN"
cat > "$COMPAT_BIN/sudo" <<'LALUNE_SUDO_SHIM'
#!/bin/sh
exec "$@"
LALUNE_SUDO_SHIM
chmod +x "$COMPAT_BIN/sudo"

# CA bundle нужен для GitHub HTTPS на минимальных OpenWRT образах.
if [ ! -e /etc/ssl/certs/ca-certificates.crt ] && [ ! -e /etc/ssl/cert.pem ]; then
  log 'CA certificates missing; trying to install them'
  install_packages ca-bundle ca-certificates || true
fi

if [ "${LALUNE_PREUPLOADED:-0}" = 1 ] && [ -s "$BACKEND_PATH" ]; then
  log 'using backend uploaded from the phone'
else
  log 'downloading LaLune OpenWRT backend'
  if ! download "$BACKEND_URL" "$BACKEND_PATH"; then
    echo "LALUNE_NEED_UPLOAD abi=$abi" >&2
    exit 28
  fi
fi
chmod +x "$BACKEND_PATH"

log 'backend contains bundled CSQTT / CSQTTR / CSQTT 2.1.9 cores'

# Останавливаем предыдущий экземпляр, если он был запущен нашим установщиком.
if [ -f "$PID_FILE" ]; then
  old_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    kill "$old_pid" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$PID_FILE"
fi
# Подхватываем и старую ручную установку, у которой pid-файла могло не быть.
if have killall; then
  killall lalune-openwrt-backend 2>/dev/null || true
  sleep 1
fi

# Автозапуск после перезагрузки роутера: служба procd (respawn при падении).
if [ -f /etc/rc.common ] && [ -d /etc/init.d ]; then
  log 'installing autostart service /etc/init.d/lalune'
  cat > /etc/init.d/lalune <<LALUNE_INITD
#!/bin/sh /etc/rc.common
START=95
STOP=10
USE_PROCD=1

start_service() {
  mkdir -p "$DATA_DIR"
  procd_open_instance
  procd_set_param command "$BACKEND_PATH"
  procd_set_param env HOME="$HOME" PATH="$COMPAT_BIN:/usr/sbin:/usr/bin:/sbin:/bin"
  procd_set_param cwd "$INSTALL_DIR"
  procd_set_param respawn 3600 5 0
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_close_instance
}
LALUNE_INITD
  chmod +x /etc/init.d/lalune
  /etc/init.d/lalune enable >/dev/null 2>&1 || true
  USE_PROCD_START=1
fi

log 'starting backend in background'
cd "$INSTALL_DIR"
if [ "${USE_PROCD_START:-0}" = 1 ]; then
  /etc/init.d/lalune restart >/dev/null 2>&1 || /etc/init.d/lalune start >/dev/null 2>&1 || true
  sleep 2
  pid="$(pidof lalune-openwrt-backend 2>/dev/null | awk '{print $1}')"
  [ -n "$pid" ] || pid=0
else
  PATH="$COMPAT_BIN:$PATH" nohup "$BACKEND_PATH" >>"$LOG_FILE" 2>&1 </dev/null &
  pid=$!
fi
echo "$pid" > "$PID_FILE"
sleep 1

if ! kill -0 "$pid" 2>/dev/null; then
  echo 'Backend exited immediately:' >&2
  tail -n 40 "$LOG_FILE" >&2 2>/dev/null || true
  exit 23
fi

printf 'LALUNE_INSTALL_OK pid=%s\n' "$pid"
''';
}
