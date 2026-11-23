#!/bin/sh
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# keenetic.sh — автоматический установщик LaLune для KeeneticOS (Entware/OPKG).
# Оптимизирован для моделей без USB (KN-3012 Speedster, KN-3110 Air) и с USB (Giga, Titan, Hopper, Viva).
# Ядра CSQTT, CSQTTR и CSQTT 2.1.9 встроены в бинарник.

set -e

BACKEND_BASE="https://github.com/mikhail384/LaLune/releases/latest/download"
BACKEND_NAME="lalune-backend"
BIN_DIR="/opt/bin"
ETC_DIR="/opt/etc/lalune"
INIT_DIR="/opt/etc/init.d"
VAR_DIR="/opt/var/lalune"
LOG_DIR="/opt/var/log"
RUN_DIR="/opt/var/run"

BACKEND_PATH="${BIN_DIR}/${BACKEND_NAME}"
INIT_SCRIPT="${INIT_DIR}/S99lalune"
PID_FILE="${RUN_DIR}/lalune.pid"
LOG_FILE="${LOG_DIR}/lalune.log"

FORCE=0
MODE="install"
for arg in "$@"; do
    case "$arg" in
        --force|-f) FORCE=1 ;;
        --stop)     MODE="stop" ;;
        --restart)  MODE="restart" ;;
        --status)   MODE="status" ;;
        --uninstall) MODE="uninstall" ;;
        -h|--help)
            echo "Использование: $0 [--force] [--stop] [--restart] [--status] [--uninstall]"
            exit 0
            ;;
    esac
done

log()  { printf "\033[1;32m[keenetic]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[keenetic][WARN]\033[0m %s\n" "$*" >&2; }
fail() { printf "\033[1;31m[keenetic][ERROR]\033[0m %s\n" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# Проверка наличия Entware
check_entware() {
    if [ ! -x "/opt/bin/opkg" ]; then
        echo ""
        fail "Entware не найден в /opt!
Пожалуйста, активируйте поддержку OPKG в KeeneticOS:
  1. В веб-интерфейсе роутера: 'Управление' -> 'Общие настройки' -> 'Изменение набора компонентов'.
  2. Установите компонент 'Поддержка открытых пакетов (OPKG)'.
  3. Для моделей без USB (KN-3012 Speedster): выберите накопитель 'Внутренняя память' (storage:).
  4. После завершения установки повторите запуск этого скрипта."
    fi
    export PATH="/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
}

read_pid() {
    [ -f "$PID_FILE" ] || return 1
    pid=$(cat "$PID_FILE" 2>/dev/null | tr -d ' \n\r')
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    echo "$pid"
}

stop_backend() {
    pid=$(read_pid 2>/dev/null || true)
    if [ -n "$pid" ]; then
        log "Останавливаю backend (PID=$pid)..."
        kill "$pid" 2>/dev/null || true
        i=0
        while [ $i -lt 6 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.5; i=$((i+1)); done
        kill -0 "$pid" 2>/dev/null && { warn "Принудительное завершение (SIGKILL)"; kill -9 "$pid" 2>/dev/null || true; }
    fi
    rm -f "$PID_FILE"
}

status_backend() {
    pid=$(read_pid 2>/dev/null || true)
    if [ -n "$pid" ]; then
        log "LaLune backend активен и работает (PID=$pid)"
        echo "Панель управления: http://$(get_lan_ip):1062/panel"
        echo "API порт: 1062"
    else
        log "LaLune backend остановлен"
    fi
}

uninstall() {
    log "Удаление LaLune..."
    stop_backend
    rm -f "$BACKEND_PATH"
    rm -f "$INIT_SCRIPT"
    rm -rf "$ETC_DIR" "$VAR_DIR"
    log "LaLune успешно удален из Entware."
    exit 0
}

get_lan_ip() {
    ip=$(ip -4 addr show br0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)
    if [ -z "$ip" ]; then
        ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
    fi
    [ -n "$ip" ] && echo "$ip" || echo "192.168.1.1"
}

check_entware

case "$MODE" in
    stop) stop_backend; exit 0 ;;
    restart) stop_backend; "$INIT_SCRIPT" start; exit 0 ;;
    status) status_backend; exit 0 ;;
    uninstall) uninstall ;;
esac

# Определение архитектуры
arch="$(uname -m 2>/dev/null || true)"
abi=""

case "$arch" in
    mips|mipsel)
        # Keenetic Speedster KN-3012, Hopper KN-3810, Viva KN-1910, Giga KN-1010
        abi="ramips"
        ;;
    aarch64|arm64)
        # Keenetic Titan KN-1811, Peak KN-2710
        abi="aarch64"
        ;;
    armv7*|armv8l)
        # Keenetic Ultra KN-2410, Giga KN-1011, Viva KN-1912
        abi="armv7"
        ;;
    x86_64)
        abi="x86_64"
        ;;
    *)
        fail "Неподдерживаемая архитектура процессора: $arch"
        ;;
esac

if [ "$abi" = "aarch64" ]; then
    BACKEND_URL="$BACKEND_BASE/lalune-openwrt-backend"
else
    BACKEND_URL="$BACKEND_BASE/lalune-openwrt-backend-$abi"
fi

log "Архитектура устройства: $arch -> сборка $abi"

# Проверка пакетов Entware
log "Проверка системных утилит в Entware..."
NEEDED_PKGS=""
for pkg in ip-full iptables curl ca-certificates ca-bundle; do
    if ! opkg list-installed 2>/dev/null | grep -q "^$pkg "; then
        NEEDED_PKGS="$NEEDED_PKGS $pkg"
    fi
done

if [ -n "$NEEDED_PKGS" ]; then
    log "Установка необходимых пакетов: $NEEDED_PKGS..."
    opkg update >/dev/null 2>&1 || true
    opkg install $NEEDED_PKGS || warn "Некоторые пакеты не удалось установить автоматически, продолжаем..."
fi

# Проверка поддержки TUN устройства
if [ ! -c /dev/net/tun ]; then
    log "Создание узла устройства /dev/net/tun..."
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200 2>/dev/null || true
    chmod 666 /dev/net/tun 2>/dev/null || true
fi

if [ ! -c /dev/net/tun ]; then
    warn "Модуль ядра TUN не обнаружен! Убедитесь, что в KeeneticOS установлен компонент 'Протокол OpenVPN' или 'Модуль ядра TUN'."
fi

# Подготовка директорий
mkdir -p "$BIN_DIR" "$ETC_DIR" "$INIT_DIR" "$VAR_DIR" "$LOG_DIR" "$RUN_DIR"

# Остановка старой версии
stop_backend

# Загрузка бинарника
log "Загрузка бинарника LaLune: $BACKEND_URL..."
TMP_BIN="/opt/tmp/lalune-backend.download"
mkdir -p /opt/tmp
rm -f "$TMP_BIN"

if have curl; then
    curl -fL --retry 3 --connect-timeout 20 -o "$TMP_BIN" "$BACKEND_URL"
elif have wget; then
    wget -O "$TMP_BIN" "$BACKEND_URL"
else
    fail "Не найден curl или wget для скачивания бинарника"
fi

chmod +x "$TMP_BIN"
mv -f "$TMP_BIN" "$BACKEND_PATH"
log "Бинарник установлен в $BACKEND_PATH"

# Создание init-скрипта Entware
cat << 'EOF' > "$INIT_SCRIPT"
#!/bin/sh
# Entware init script for LaLune VPN backend on KeeneticOS

ENABLED=yes
PROCS=lalune-backend
NAME=lalune-backend
BIN_PATH=/opt/bin/lalune-backend
PID_FILE=/opt/var/run/lalune.pid
LOG_FILE=/opt/var/log/lalune.log
RUN_DIR=/opt/var/lalune

export PATH="/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export HOME="/opt/root"

start() {
    [ "$ENABLED" = "yes" ] || exit 0
    if [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
        echo "$NAME is already running (PID=$(cat $PID_FILE))."
        return 0
    fi
    
    echo "Starting $NAME..."
    mkdir -p /opt/var/run /opt/var/log /opt/var/lalune /dev/net
    [ -c /dev/net/tun ] || mknod /dev/net/tun c 10 200 2>/dev/null || true
    
    cd "$RUN_DIR"
    nohup "$BIN_PATH" > "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    echo "$NAME started (PID=$(cat $PID_FILE))."
}

stop() {
    echo "Stopping $NAME..."
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$PID" ]; then
            kill "$PID" 2>/dev/null || true
            sleep 1
            kill -0 "$PID" 2>/dev/null && kill -9 "$PID" 2>/dev/null || true
        fi
        rm -f "$PID_FILE"
    fi
    echo "$NAME stopped."
}

status() {
    if [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
        echo "$NAME is running (PID=$(cat $PID_FILE))."
    else
        echo "$NAME is not running."
    fi
}

case "$1" in
    start)   start ;;
    stop)    stop ;;
    restart) stop; sleep 1; start ;;
    status)  status ;;
    *)       echo "Usage: $0 {start|stop|restart|status}"; exit 1 ;;
esac
EOF

chmod +x "$INIT_SCRIPT"
log "Служба автозапуска создана: $INIT_SCRIPT"

# Запуск службы
log "Запуск службы LaLune..."
"$INIT_SCRIPT" start

sleep 2
if read_pid >/dev/null 2>&1; then
    LAN_IP=$(get_lan_ip)
    echo ""
    log "=========================================================="
    log "🎉 LaLune успешно установлен и запущен на KeeneticOS!"
    log "=========================================================="
    echo ""
    echo "  Веб-панель управления: http://${LAN_IP}:1062/panel"
    echo "  REST API / SSE:        http://${LAN_IP}:1062"
    echo "  Логи службы:           cat /opt/var/log/lalune.log"
    echo "  Управление службой:    /opt/etc/init.d/S99lalune {start|stop|restart|status}"
    echo ""
    echo "  Также вы можете управлять роутером из мобильного приложения LaLune,"
    echo "  указав IP роутера (${LAN_IP}:1062) в настройках подключения."
    echo ""
else
    warn "Служба запущена, но PID не обнаружен. Проверьте журнал: cat /opt/var/log/lalune.log"
fi
