#!/bin/sh
# Read-only OpenWrt sample. Never prints command lines, configuration or addresses.
set -u
printf 'LaLune OpenWrt read-only diagnostics\n'
[ -r /tmp/sysinfo/model ] && { printf 'Model: '; cat /tmp/sysinfo/model; }
[ -r /etc/openwrt_release ] && sed -n '/^DISTRIB_RELEASE=/p' /etc/openwrt_release
uname -m
awk '/^MemTotal:|^MemAvailable:/ {print}' /proc/meminfo
for dev in lalune0; do
  if [ -d "/sys/class/net/$dev" ]; then
    printf '%s MTU: ' "$dev"; cat "/sys/class/net/$dev/mtu"
    for metric in rx_bytes tx_bytes rx_packets tx_packets rx_dropped tx_dropped rx_errors tx_errors; do
      [ -r "/sys/class/net/$dev/statistics/$metric" ] && printf '%s %s\n' "$metric" "$(cat "/sys/class/net/$dev/statistics/$metric")"
    done
  else
    printf '%s: absent\n' "$dev"
  fi
done
sample() {
  printf '\nCPU counters: '; awk '/^cpu / {print $2, $3, $4, $5, $6, $7, $8; exit}' /proc/stat
  for proc in /proc/[0-9]*; do
    [ -r "$proc/comm" ] && [ -r "$proc/stat" ] || continue
    name=$(cat "$proc/comm" 2>/dev/null) || continue
    case "$name" in *lalune*|*LaLune*|*csqtt*|*CSQTT*)
      # Strip PID and parenthesized comm; the following fields start at state (3).
      vals=$(sed 's/^.*) //' "$proc/stat" 2>/dev/null | awk '{print $12, $13, $18}') || continue
      printf 'Process %s PID %s: user_ticks system_ticks threads = %s\n' "$name" "${proc##*/}" "$vals";;
    esac
  done
}
sample
sleep 5
sample
printf '\nTunnel counters after 5 s:\n'
for metric in rx_bytes tx_bytes rx_packets tx_packets rx_dropped tx_dropped rx_errors tx_errors; do
  [ -r "/sys/class/net/lalune0/statistics/$metric" ] && printf '%s %s\n' "$metric" "$(cat "/sys/class/net/lalune0/statistics/$metric")"
done
exit 0
