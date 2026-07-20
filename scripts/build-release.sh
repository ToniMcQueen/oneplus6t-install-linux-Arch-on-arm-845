#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${1:-oneplus-fajita}"
PROFILE_DIR="$ROOT_DIR/profiles/$PROFILE"

if [[ -f "$PROFILE_DIR/config.env" ]]; then
  # shellcheck source=/dev/null
  source "$PROFILE_DIR/config.env"
fi

# shellcheck source=scripts/lib/privilege.sh
source "$ROOT_DIR/scripts/lib/privilege.sh"

ROOT_IMAGE_SIZE_FROM_FASTBOOT="${ROOT_IMAGE_SIZE_FROM_FASTBOOT:-0}"
FASTBOOT_PROBE_TIMEOUT_SECONDS="${FASTBOOT_PROBE_TIMEOUT_SECONDS:-3}"
ALLOW_FASTBOOT_USERDATA_SIZE_FALLBACK="${ALLOW_FASTBOOT_USERDATA_SIZE_FALLBACK:-1}"

fastboot_getvar_value() {
  local key="$1"
  local attempt output value

  for attempt in 1 2 3; do
    output="$(timeout "${FASTBOOT_PROBE_TIMEOUT_SECONDS}s" fastboot getvar "$key" 2>&1 || true)"
    value="$(
      printf '%s\n' "$output" |
        awk -v key="$key" '
          index($0, key ":") {
            sub(/^.*: */, "")
            gsub(/\r/, "")
            print
            exit
          }
        '
    )"
    if [[ -n "$value" ]]; then
      printf '%s\n' "$value"
      return
    fi
    sleep 1
  done

  if [[ "$key" == "partition-size:userdata" && \
        "$ALLOW_FASTBOOT_USERDATA_SIZE_FALLBACK" == "1" && \
        -n "${FASTBOOT_USERDATA_SIZE_FALLBACK_HEX:-}" ]]; then
    echo "WARN: could not capture fastboot userdata size; using profile fallback $FASTBOOT_USERDATA_SIZE_FALLBACK_HEX" >&2
    printf '%s\n' "$FASTBOOT_USERDATA_SIZE_FALLBACK_HEX"
    return
  fi

  echo "Could not read fastboot getvar $key" >&2
  printf '%s\n' "$output" >&2
  exit 1
}

resolve_root_image_size_from_fastboot() {
  if ! command -v fastboot >/dev/null 2>&1; then
    echo "Missing required tool for ROOT_IMAGE_SIZE_FROM_FASTBOOT=1: fastboot" >&2
    exit 1
  fi

  local userdata_hex userdata_bytes
  userdata_hex="$(fastboot_getvar_value partition-size:userdata)"
  case "$userdata_hex" in
    0x*|0X*) ;;
    *)
      echo "Unexpected userdata size from fastboot: $userdata_hex" >&2
      exit 1
      ;;
  esac

  userdata_bytes=$((userdata_hex))
  if (( userdata_bytes <= 0 )); then
    echo "Invalid userdata partition size: $userdata_bytes" >&2
    exit 1
  fi

  ROOT_IMAGE_SIZE="$userdata_bytes"
  echo "Resolved ROOT_IMAGE_SIZE=$ROOT_IMAGE_SIZE bytes from fastboot userdata ($userdata_hex)."
}

if [[ "$ROOT_IMAGE_SIZE_FROM_FASTBOOT" == "1" || "${ROOT_IMAGE_SIZE:-}" == "fastboot-userdata" ]]; then
  resolve_root_image_size_from_fastboot
fi

ROOTFS_ENV_NAMES=(
  ARCHLINUXARM_ROOTFS_URL
  ARCH_ROOTFS_TARBALL
  ROOT_LABEL
  ROOT_UUID
  ROOT_DEVICE
  ROOT_IMAGE_SIZE
  BTRFS_MKFS_FEATURES
  PMOS_BOOT_DIR
  PMOS_KERNEL
  PMOS_DTB
  PMOS_INITRAMFS
  PMOS_INITRAMFS_EXTRA
  PMOS_EMBED_INITRAMFS_EXTRA
  BOOT_KERNEL_SOURCE
  CAMERA_KERNEL_PACKAGE_GLOB
  CAMERA_PACKAGE_MANIFEST
  ENABLE_CAMERA_USERSPACE
  BOOT_BASE
  BOOT_KERNEL_OFFSET
  BOOT_RAMDISK_OFFSET
  BOOT_SECOND_OFFSET
  BOOT_TAGS_OFFSET
  BOOT_PAGESIZE
  BOOT_HEADER_VERSION
  BOOT_CMDLINE
  ALLOW_INSECURE_DEFAULT_PASSWORD
  INSECURE_ROOT_PASSWORD
  INSECURE_ALARM_PASSWORD
  INSTALL_USERNAME
  INSTALL_WIFI_SSID
  INSTALL_WIFI_PASSWORD
  INSTALL_MOBILE_APN
  INSTALL_MOBILE_APN_USER
  INSTALL_MOBILE_APN_PASSWORD
  INSTALL_APP_LAUNCHER_PACKAGE
  INSTALL_APP_LAUNCHER_COMMAND
  INSTALL_APP_LAUNCHER_KEY
  INSTALL_BOOTANIMATION_ENABLE
  INSTALL_BOOTANIMATION_ZIP
  SSH_AUTHORIZED_KEYS_FILE
  SSH_AUTHORIZED_KEYS_GLOB
  SSH_AUTHORIZED_KEYS
  DISABLE_SSH_PASSWORD_AUTH
  INSTALL_ROOT_SSH_KEYS
  INSTALL_PROFILE_PACKAGES
  ENABLE_HEXAGON_SENSORS
  ENABLE_QCOM_REMOTEPROC
  ENABLE_PMOS_COMPAT_UNITS
  ENABLE_QCOM_RADIO
  ENABLE_QCOM_WIFI
  WVKBD_REF
  WVKBD_SOURCE_CACHE_DIR
  HYPERROTATION_REF
  HYPERROTATION_SOURCE_CACHE_DIR
  PMOS_COMPAT_PAYLOAD_DIR
  PMOS_HARDWARE_REFERENCE_TARBALL
  OUT_DIR
  CACHE_DIR
  WORK_DIR
  PACKAGE_MANIFEST
  PACMAN_CACHE_DIR
  LOCAL_PACKAGE_DIR
)

rootfs_env_args() {
  local name
  for name in "${ROOTFS_ENV_NAMES[@]}"; do
    if [[ -v "$name" ]]; then
      printf '%s=%s\0' "$name" "${!name}"
    fi
  done
}

case "${BOOT_KERNEL_SOURCE:-pmos-snapshot}" in
  pmos-snapshot)
    ;;
  camera-package)
    "$ROOT_DIR/scripts/build-camera-kernel-package.sh" "$PROFILE"
    ;;
  *)
    echo "Unsupported BOOT_KERNEL_SOURCE: $BOOT_KERNEL_SOURCE" >&2
    exit 1
    ;;
esac

"$ROOT_DIR/scripts/build-bootimg.sh" "$PROFILE"

if [[ "${ENABLE_HEXAGON_SENSORS:-1}" == "1" ]]; then
  "$ROOT_DIR/scripts/build-hexagonrpcd-package.sh" "$PROFILE"
fi

echo
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  echo "Running root image builder as root."
else
  select_root_runner
  echo "Running root image builder via ${ROOT_RUNNER[*]}."
fi

mapfile -d '' -t ROOTFS_ENV < <(rootfs_env_args)
run_env_as_root "${ROOTFS_ENV[@]}" "$ROOT_DIR/scripts/build-rootfs-image.sh" "$PROFILE"

OUT_DIR="${OUT_DIR:-$ROOT_DIR/out/$PROFILE}"

echo
echo "Release artifacts:"
find "$OUT_DIR" -maxdepth 1 -type f \( -name '*.img' -o -name '*.sha256' \) -printf '%p\n' | sort
