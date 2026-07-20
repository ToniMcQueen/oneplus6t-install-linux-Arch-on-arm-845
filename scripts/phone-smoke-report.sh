#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${1:-oneplus-fajita}"
PHONE_SSH_TARGET="${PHONE_SSH_TARGET:-alarm@172.16.42.1}"
PHONE_SSH_CONNECT_TIMEOUT="${PHONE_SSH_CONNECT_TIMEOUT:-8}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/out/$PROFILE}"
REPORT="${REPORT:-$OUT_DIR/phone-smoke-$(date -u +%Y%m%dT%H%M%SZ).txt}"

mkdir -p "$OUT_DIR"

ssh_opts=(
  -F /dev/null
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout="$PHONE_SSH_CONNECT_TIMEOUT"
  -o PubkeyAuthentication=no
  -o PreferredAuthentications=password,keyboard-interactive
  -o NumberOfPasswordPrompts=1
  -o IdentitiesOnly=yes
)

ssh "${ssh_opts[@]}" "$PHONE_SSH_TARGET" 'bash -s' > "$REPORT" <<'REMOTE'
set -u

section() {
  printf '\n== %s ==\n' "$*"
}

run() {
  printf '$ %s\n' "$*"
  "$@" 2>&1 || true
}

run_shell() {
  printf '$ %s\n' "$*"
  sh -c "$*" 2>&1 || true
}

section "Identity"
run date -u
run uname -a
run findmnt -n -o SOURCE,FSTYPE,OPTIONS /
run cat /proc/cmdline
run_shell "cat /etc/os-release | sed -n '1,8p'"

section "Boot Files"
run_shell "ls -l /boot/initramfs /boot/initramfs-extra /boot/vmlinuz /boot/sdm845-oneplus-fajita.dtb /boot/linux.efi"
run systemctl --failed --no-pager

section "Release Services"
run systemctl status oneplus6t-root-resize.service --no-pager
run systemctl status oneplus6t-pacman-keyring.service --no-pager
run systemctl status oneplus6t-wvkbd-build.service --no-pager
run systemctl status oneplus6t-hyperrotation-build.service --no-pager
run systemctl status oneplus6t-power-key-inhibit.service --no-pager
run systemctl status oneplus6t-keychords.service --no-pager
run systemctl status oneplus6t-uim-select.service --no-pager
run systemctl status oneplus6t-mobile-data.service --no-pager
run systemctl status oneplus6t-bluetooth-address.service --no-pager
run systemctl status oneplus6t-qcom-radio.service --no-pager
run systemctl status oneplus6t-wifi-remoteproc.service --no-pager
run systemctl status pmos-compat-tqftpserv.service --no-pager
run systemctl status pmos-compat-rmtfs.service --no-pager
run systemctl status pmos-compat-pd-mapper.service --no-pager

section "Package Trust"
run pacman-key --list-keys
run_shell "ls -l /var/lib/oneplus6t/pacman-keyring-ready /etc/pacman.d/gnupg/pubring.gpg /etc/pacman.d/gnupg/pubring.kbx 2>/dev/null || true"

section "Hyprland UI"
run pgrep -a Hyprland
run_shell "pgrep -a 'wvkbd' || true"
run_shell "ls -l /home/alarm/.config/hypr/plugins/hyperrotation.so /usr/local/bin/start-hyprland /usr/local/bin/oneplus6t-lock /usr/local/bin/oneplus6t-osk /usr/local/bin/wvkbd-deskintl /usr/local/bin/oneplus6t-terminal"
run_shell "sed -n '1,180p' /home/alarm/.config/hypr/conf.d/10-oneplus6t-controls.conf"

section "Display GPU Input"
run_shell "ls -l /dev/dri /dev/input/by-path"
run_shell "find /sys/class/drm -maxdepth 2 -type f -name status -print -exec cat {} \\;"
run_shell "grep -H . /sys/class/graphics/fb*/name 2>/dev/null"

section "Audio Haptics Flash"
run_shell "wpctl status | sed -n '1,120p'"
run_shell "grep -H . /proc/bus/input/devices | grep -Ei 'haptic|spmi|volume|power' -C 2"
run_shell 'for led in /sys/class/leds/*flash* /sys/class/leds/*torch*; do [ -e "$led" ] && echo "$led max=$(cat "$led/max_brightness" 2>/dev/null) current=$(cat "$led/brightness" 2>/dev/null)"; done'

section "Camera"
run_shell "pacman -Q linux-oneplus6t-camera 2>/dev/null || echo linux-oneplus6t-camera-not-installed"
run_shell "ls -l /dev/media* /dev/video* /dev/v4l-subdev* 2>/dev/null || true"
run_shell "lsmod | grep -E '(^camss|imx371|imx376|imx519|videodev|v4l2_)' || true"
run_shell "command -v oneplus6t-camera-info >/dev/null && oneplus6t-camera-info || true"

section "Sensors"
run_shell "ls -l /dev/fastrpc* 2>/dev/null || true"
run_shell "ls -l /opt/pmos-compat/bin/tqftpserv /opt/pmos-compat/sbin/rmtfs /opt/pmos-compat/bin/pd-mapper /usr/lib/ld-musl-aarch64.so.1 2>/dev/null || true"
run_shell "lsmod | grep -E '(^fastrpc|qcom_q6v5|qcom_sysmon|qrtr|ath10k|btq)' || true"
run_shell 'for f in /sys/class/remoteproc/remoteproc*/name /sys/class/remoteproc/remoteproc*/state /sys/class/remoteproc/remoteproc*/firmware; do [ -e "$f" ] && printf "%s: " "$f" && cat "$f"; done'
run systemctl is-enabled hexagonrpcd-sdsp.service iio-sensor-proxy.service
run systemctl is-active hexagonrpcd-sdsp.service iio-sensor-proxy.service
run systemctl status hexagonrpcd-sdsp.service iio-sensor-proxy.service --no-pager
run_shell "udevadm info --query=property --path=/sys/class/misc/fastrpc-sdsp 2>/dev/null | grep -E '^(IIO_SENSOR_PROXY_TYPE|ACCEL_MOUNT_MATRIX)='"
run_shell "timeout -k 2s 10s monitor-sensor"

section "Networking WiFi Bluetooth"
run ip -br addr
run nmcli device status
run_shell "nmcli -f NAME,TYPE,AUTOCONNECT connection show"
run bluetoothctl show
run rfkill list

section "Mobile Data"
run mmcli -L
run mmcli -m 0
run /usr/local/sbin/oneplus6t-mobile-data status

section "GPS GNSS"
run_shell "pacman -Q gpsd geoclue 2>/dev/null || true"
run_shell "ls -l /dev/gnss* /dev/gps* /dev/wwan* /dev/modem 2>/dev/null || true"
run mmcli -m 0 --location-status
run mmcli -m 0 --location-get
run_shell "command -v qmicli >/dev/null && qmicli -pd qrtr://0 --loc-get-engine-lock || true"
run_shell "command -v qmicli >/dev/null && qmicli -pd qrtr://0 --loc-get-operation-mode || true"
run_shell "command -v qmicli >/dev/null && qmicli -pd qrtr://0 --loc-get-nmea-types || true"
run_shell "command -v oneplus6t-gps >/dev/null && oneplus6t-gps status || true"

section "Power Suspend USB-C"
run_shell "cat /sys/power/state /sys/power/mem_sleep 2>/dev/null"
run_shell "cat /sys/power/disk 2>/dev/null || true"
run_shell "cat /proc/swaps"
run_shell "grep -o 'resume=[^ ]*' /proc/cmdline || true"
run systemctl status oneplus6t-cpu-power.service --no-pager
run_shell "command -v oneplus6t-cpu-power >/dev/null && oneplus6t-cpu-power status || true"
run_shell "find /sys/class/typec /sys/class/usb_role /sys/class/extcon -maxdepth 2 -type f -print -exec cat {} \\; 2>/dev/null"
run_shell "upower -d | sed -n '1,180p'"

section "Crash Evidence"
run_shell "find /sys/fs/pstore -maxdepth 1 -type f -printf '%f %s bytes\\n' 2>/dev/null | sort"
run_shell "journalctl -b --no-pager | grep -Ei 'crash|panic|fatal|oops|segfault|modem|bluetooth|wlan|ath10k|qmi|gnss|gps|location|sensor|iio|sdsp|fastrpc|hypr|wvkbd' | tail -n 260"
REMOTE

echo "Wrote phone smoke report:"
echo "$REPORT"
