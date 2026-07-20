#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${1:-oneplus-fajita}"

# shellcheck source=scripts/lib/privilege.sh
source "$ROOT_DIR/scripts/lib/privilege.sh"

# shellcheck source=scripts/package-name-aliases.sh
source "$ROOT_DIR/scripts/package-name-aliases.sh"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<EOF
Usage: $0 [profile]

Builds and flashes the OnePlus 6T release image from fastboot.

Long-term userdata safety rule:
  1. Query the live fastboot userdata partition size.
  2. Build the Btrfs root image with that virtual size.
  3. Flash only after strict preflight confirms the root image spans userdata.

This avoids the stale Btrfs/userdata tail problem without touching dtbo or
requiring the /dev/sda14 rescue system.
EOF
  exit 0
fi

cd "$ROOT_DIR"

echo "OnePlus 6T release install"
echo "Profile: $PROFILE"
echo
echo "This is destructive: it replaces boot and userdata."
echo "It does not erase dtbo, modem, vendor, persist, or other Android partitions."
echo

# Public-alpha installer access contract. The lower-level rootfs builder keeps
# password login disabled by default, but this end-to-end test installer needs a
# predictable rescue path until first-boot onboarding exists.
export ALLOW_INSECURE_DEFAULT_PASSWORD="${ALLOW_INSECURE_DEFAULT_PASSWORD:-1}"
INSTALLER_SETUP_PROMPT="${INSTALLER_SETUP_PROMPT:-auto}"
INSTALLER_PASSWORD_PROMPT="${INSTALLER_PASSWORD_PROMPT:-auto}"
FASTBOOT_PROBE_TIMEOUT_SECONDS="${FASTBOOT_PROBE_TIMEOUT_SECONDS:-3}"
FASTBOOT_READY_WAIT_SECONDS="${FASTBOOT_READY_WAIT_SECONDS:-120}"
FASTBOOT_READY_RETRY_SECONDS="${FASTBOOT_READY_RETRY_SECONDS:-2}"

wait_for_fastboot_ready() {
  local context="$1"
  local elapsed=0

  echo "Waiting for fastboot command readiness: $context"
  while (( elapsed <= FASTBOOT_READY_WAIT_SECONDS )); do
    if timeout "${FASTBOOT_PROBE_TIMEOUT_SECONDS}s" fastboot getvar product >/dev/null 2>&1 && \
       timeout "${FASTBOOT_PROBE_TIMEOUT_SECONDS}s" fastboot getvar partition-size:userdata >/dev/null 2>&1; then
      echo "OK: fastboot product and userdata-size getvars returned."
      return 0
    fi

    if (( elapsed == 0 )); then
      cat >&2 <<'EOF'
Fastboot is not accepting commands yet.

`fastboot devices` can list a phone while getvar/flash commands are briefly
wedged after a USB reset or a long build. If the phone dropped out of fastboot,
put it back into fastboot now and leave it connected.
EOF
    fi

    sleep "$FASTBOOT_READY_RETRY_SECONDS"
    elapsed=$((elapsed + FASTBOOT_READY_RETRY_SECONDS))
  done

  echo "Fastboot did not become command-ready within ${FASTBOOT_READY_WAIT_SECONDS}s." >&2
  echo "Current fastboot device list:" >&2
  fastboot devices -l >&2 || true
  exit 1
}

prompt_is_allowed() {
  local setting="$1"
  local name="$2"

  case "$setting" in
    0|false|False|FALSE|no|No|NO|never)
      return 1
      ;;
    1|true|True|TRUE|yes|Yes|YES|always)
      if [[ -t 0 && -t 2 ]]; then
        return 0
      fi
      echo "$name=$setting requires an interactive terminal." >&2
      exit 1
      ;;
    auto|"")
      [[ -t 0 && -t 2 ]]
      ;;
    *)
      echo "Invalid $name=$setting" >&2
      echo "Use auto, 1, or 0." >&2
      exit 1
      ;;
  esac
}

setup_prompt_is_allowed() {
  prompt_is_allowed "$INSTALLER_SETUP_PROMPT" INSTALLER_SETUP_PROMPT
}

password_prompt_is_allowed() {
  prompt_is_allowed "$INSTALLER_PASSWORD_PROMPT" INSTALLER_PASSWORD_PROMPT
}

valid_linux_username() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

valid_no_newline() {
  [[ "$1" != *$'\n'* && "$1" != *$'\r'* ]]
}

valid_profile_package_name() {
  [[ "$1" =~ ^[A-Za-z0-9@._+:-]+$ ]]
}

valid_launcher_command() {
  [[ -n "$1" && "$1" != *$'\n'* && "$1" != *$'\r'* && "$1" != *","* ]]
}

default_launcher_command_for_package() {
  case "$1" in
    wofi)
      printf '%s\n' "wofi --show drun"
      ;;
    rofi|rofi-wayland)
      printf '%s\n' "rofi -show drun"
      ;;
    *)
      printf '%s\n' "$1"
      ;;
  esac
}

normalize_app_launcher_key() {
  local key="$1"
  printf '%s' "${key^^}"
}

valid_app_launcher_key() {
  local key
  key="$(normalize_app_launcher_key "$1")"

  [[ "$key" =~ ^[A-Z]$ ]] || return 1
  case "$key" in
    Q|H|C|K)
      return 1
      ;;
  esac
}

valid_boot_video_value() {
  [[ "$1" != *$'\n'* && "$1" != *$'\r'* ]]
}

kernel_track_from_boot_source() {
  case "${1:-}" in
    ""|pmos-snapshot)
      printf '%s\n' "stable"
      ;;
    camera-package)
      printf '%s\n' "camera"
      ;;
    *)
      return 1
      ;;
  esac
}

normalize_kernel_track() {
  local value="$1"

  case "${value,,}" in
    ""|stable|s|pmos|pmos-snapshot|golden)
      printf '%s\n' "stable"
      ;;
    camera|c|experimental|unstable|camera-package)
      printf '%s\n' "camera"
      ;;
    *)
      return 1
      ;;
  esac
}

apply_kernel_track() {
  local track="$1"

  case "$track" in
    stable)
      BOOT_KERNEL_SOURCE="pmos-snapshot"
      ENABLE_CAMERA_USERSPACE="0"
      ;;
    camera)
      BOOT_KERNEL_SOURCE="camera-package"
      ENABLE_CAMERA_USERSPACE="1"
      ;;
    *)
      echo "Invalid INSTALL_KERNEL_TRACK=$track" >&2
      echo "Use stable or camera." >&2
      exit 1
      ;;
  esac
}

prompt_for_kernel_track() {
  local output_var="$1"
  local value normalized

  while true; do
    printf 'Kernel track [stable kernel or camera kernel; Enter=stable]: ' >&2
    IFS= read -r value

    if normalized="$(normalize_kernel_track "$value")"; then
      printf -v "$output_var" '%s' "$normalized"
      return
    fi

    echo "Choose stable for the recommended PMOS 6.9 kernel, or camera for the experimental IMX519 kernel." >&2
  done
}

prompt_for_value() {
  local label="$1"
  local default="$2"
  local output_var="$3"
  local validator="$4"
  local value

  while true; do
    if [[ -n "$default" ]]; then
      printf '%s [%s]: ' "$label" "$default" >&2
    else
      printf '%s [Enter=skip]: ' "$label" >&2
    fi
    IFS= read -r value
    value="${value:-$default}"

    if "$validator" "$value"; then
      printf -v "$output_var" '%s' "$value"
      return
    fi

    echo "That value is not valid here. Try again, or press Enter for the default." >&2
  done
}

prompt_for_optional_value() {
  local label="$1"
  local output_var="$2"
  local validator="$3"
  local value

  while true; do
    printf '%s [Enter=skip]: ' "$label" >&2
    IFS= read -r value

    if [[ -z "$value" ]]; then
      printf -v "$output_var" '%s' ""
      return
    fi

    if "$validator" "$value"; then
      printf -v "$output_var" '%s' "$value"
      return
    fi

    echo "That value is not valid here. Type a package name, or press Enter to skip." >&2
  done
}

prompt_for_app_launcher_key() {
  local output_var="$1"
  local value normalized

  while true; do
    printf 'SUPER launcher key [S; reserved: Q, H, C, K, and workspace numbers]: ' >&2
    IFS= read -r value
    value="${value:-S}"
    normalized="$(normalize_app_launcher_key "$value")"

    if valid_app_launcher_key "$normalized"; then
      printf -v "$output_var" '%s' "$normalized"
      return
    fi

    echo "Choose one letter that is not already used by the phone controls." >&2
    echo "Reserved: SUPER+Q terminal, SUPER+H keyboard kill, SUPER+C close, SUPER+K keyboard toggle, SUPER+1..0 workspaces." >&2
  done
}

prompt_for_optional_secret() {
  local label="$1"
  local output_var="$2"
  local value

  printf '%s [Enter=skip]: ' "$label" >&2
  IFS= read -r -s value
  printf '\n' >&2
  if ! valid_no_newline "$value"; then
    echo "Invalid value." >&2
    exit 1
  fi
  printf -v "$output_var" '%s' "$value"
}

prompt_for_boot_video() {
  local output_var="$1"
  local value

  while true; do
    printf 'Boot intro video [Enter=bundled, none=verbose, or paste video path]: ' >&2
    IFS= read -r value

    if [[ -z "$value" ]]; then
      printf -v "$output_var" '%s' "bundled"
      return
    fi

    if ! valid_boot_video_value "$value"; then
      echo "That value is not valid here." >&2
      continue
    fi

    case "$value" in
      none|None|NONE|no|No|NO|off|Off|OFF|verbose|Verbose|VERBOSE|bundled|Bundled|BUNDLED|default|Default|DEFAULT)
        printf -v "$output_var" '%s' "$value"
        return
        ;;
      *)
        if [[ -f "$value" ]]; then
          printf -v "$output_var" '%s' "$value"
          return
        fi
        echo "Video file not found. Press Enter for bundled video, type none for verbose boot, or paste an existing video path." >&2
        ;;
    esac
  done
}

append_package_to_manifest() {
  local manifest="$1"
  local package="$2"

  [[ -n "$package" ]] || return 0
  if [[ ! -f "$manifest" ]]; then
    echo "Cannot add launcher package; missing package manifest: $manifest" >&2
    exit 1
  fi

  if awk -v package="$package" '
    $0 !~ /^[[:space:]]*(#|$)/ && $1 == package { found = 1 }
    END { exit !found }
  ' "$manifest"; then
    echo "Launcher package already present in selected manifest: $package"
    return 0
  fi

  {
    printf '\n'
    printf '# Added by installer for SUPER+%s app launcher\n' "${INSTALL_APP_LAUNCHER_KEY:-S}"
    printf '%s\n' "$package"
  } >> "$manifest"
  echo "Added launcher package to selected manifest: $package"
}

prompt_yes_no() {
  local label="$1"
  local default="$2"
  local output_var="$3"
  local value

  while true; do
    printf '%s [%s]: ' "$label" "$default" >&2
    IFS= read -r value
    value="${value:-$default}"
    case "$value" in
      y|Y|yes|YES|Yes)
        printf -v "$output_var" '%s' "yes"
        return
        ;;
      n|N|no|NO|No)
        printf -v "$output_var" '%s' "no"
        return
        ;;
      *)
        echo "Please answer yes or no." >&2
        ;;
    esac
  done
}

prompt_for_password() {
  local label="$1"
  local output_var="$2"
  local source_var="$3"
  local password confirm

  while true; do
    printf '%s password [Enter=temporary default]: ' "$label" >&2
    IFS= read -r -s password
    printf '\n' >&2

    if [[ -z "$password" ]]; then
      printf -v "$output_var" '%s' "alarm"
      printf -v "$source_var" '%s' "temporary default"
      return
    fi

    printf 'Confirm %s password: ' "$label" >&2
    IFS= read -r -s confirm
    printf '\n' >&2

    if [[ "$password" == "$confirm" ]]; then
      printf -v "$output_var" '%s' "$password"
      printf -v "$source_var" '%s' "installer prompt"
      return
    fi

    echo "Passwords did not match. Try again, or press Enter to use the temporary default." >&2
  done
}

echo "== image setup =="
INSTALL_USERNAME="${INSTALL_USERNAME:-alarm}"
INSTALL_WIFI_SSID="${INSTALL_WIFI_SSID:-}"
INSTALL_WIFI_PASSWORD="${INSTALL_WIFI_PASSWORD:-}"
INSTALL_MOBILE_APN="${INSTALL_MOBILE_APN:-}"
INSTALL_MOBILE_APN_USER="${INSTALL_MOBILE_APN_USER:-}"
INSTALL_MOBILE_APN_PASSWORD="${INSTALL_MOBILE_APN_PASSWORD:-}"
INSTALL_APP_LAUNCHER_PACKAGE="${INSTALL_APP_LAUNCHER_PACKAGE:-}"
INSTALL_APP_LAUNCHER_COMMAND="${INSTALL_APP_LAUNCHER_COMMAND:-}"
INSTALL_APP_LAUNCHER_KEY="${INSTALL_APP_LAUNCHER_KEY:-S}"
INSTALL_BOOT_VIDEO="${INSTALL_BOOT_VIDEO:-}"
INSTALL_BOOTANIMATION_ENABLE="${INSTALL_BOOTANIMATION_ENABLE:-}"
INSTALL_BOOTANIMATION_ZIP="${INSTALL_BOOTANIMATION_ZIP:-}"
INSTALL_KERNEL_TRACK="${INSTALL_KERNEL_TRACK:-}"
BOOT_KERNEL_SOURCE="${BOOT_KERNEL_SOURCE:-}"
ENABLE_CAMERA_USERSPACE="${ENABLE_CAMERA_USERSPACE:-}"
CAMERA_KERNEL_PACKAGE_GLOB="${CAMERA_KERNEL_PACKAGE_GLOB:-linux-oneplus6t-camera-*-aarch64.pkg.tar.*}"

if setup_prompt_is_allowed; then
  echo "Choose optional image settings. Press Enter to keep defaults or skip."
  if [[ -z "$INSTALL_KERNEL_TRACK" && -z "$BOOT_KERNEL_SOURCE" ]]; then
    prompt_for_kernel_track INSTALL_KERNEL_TRACK
  fi

  if [[ "${INSTALL_USERNAME_PROMPT_SKIP:-0}" != "1" ]]; then
    prompt_for_value "Linux username" "$INSTALL_USERNAME" INSTALL_USERNAME valid_linux_username
  fi

  if [[ -z "$INSTALL_WIFI_SSID" ]]; then
    prompt_for_value "Wi-Fi network name/SSID" "" INSTALL_WIFI_SSID valid_no_newline
  fi
  if [[ -n "$INSTALL_WIFI_SSID" && -z "$INSTALL_WIFI_PASSWORD" ]]; then
    prompt_for_optional_secret "Wi-Fi password" INSTALL_WIFI_PASSWORD
  fi

  if [[ -z "$INSTALL_MOBILE_APN" ]]; then
    prompt_yes_no "Configure mobile-data APN now?" "no" configure_apn
    if [[ "$configure_apn" == "yes" ]]; then
      prompt_for_value "Mobile APN" "" INSTALL_MOBILE_APN valid_no_newline
      if [[ -n "$INSTALL_MOBILE_APN" ]]; then
        prompt_for_value "APN username" "" INSTALL_MOBILE_APN_USER valid_no_newline
        prompt_for_optional_secret "APN password" INSTALL_MOBILE_APN_PASSWORD
      fi
    fi
  fi

  if [[ -z "$INSTALL_APP_LAUNCHER_PACKAGE" && -z "$INSTALL_APP_LAUNCHER_COMMAND" ]]; then
    prompt_yes_no "Set up a SUPER-key app launcher shortcut?" "no" configure_launcher
    if [[ "$configure_launcher" == "yes" ]]; then
      prompt_for_app_launcher_key INSTALL_APP_LAUNCHER_KEY
      prompt_for_optional_value "Application launcher package, for example nwg-menu, fuzzel, wofi, or rofi" INSTALL_APP_LAUNCHER_PACKAGE valid_profile_package_name
      if [[ -n "$INSTALL_APP_LAUNCHER_PACKAGE" ]]; then
        INSTALL_APP_LAUNCHER_PACKAGE="$(normalize_profile_package_name "$INSTALL_APP_LAUNCHER_PACKAGE")"
        INSTALL_APP_LAUNCHER_COMMAND="$(default_launcher_command_for_package "$INSTALL_APP_LAUNCHER_PACKAGE")"
      fi
    fi
  elif [[ -n "$INSTALL_APP_LAUNCHER_PACKAGE" && -z "$INSTALL_APP_LAUNCHER_COMMAND" ]]; then
    INSTALL_APP_LAUNCHER_PACKAGE="$(normalize_profile_package_name "$INSTALL_APP_LAUNCHER_PACKAGE")"
    INSTALL_APP_LAUNCHER_COMMAND="$(default_launcher_command_for_package "$INSTALL_APP_LAUNCHER_PACKAGE")"
  fi

  if [[ -z "$INSTALL_BOOT_VIDEO" && -z "$INSTALL_BOOTANIMATION_ENABLE" && -z "$INSTALL_BOOTANIMATION_ZIP" ]]; then
    prompt_for_boot_video INSTALL_BOOT_VIDEO
  fi
fi

if [[ -z "$INSTALL_KERNEL_TRACK" ]]; then
  if [[ -n "$BOOT_KERNEL_SOURCE" ]]; then
    if ! INSTALL_KERNEL_TRACK="$(kernel_track_from_boot_source "$BOOT_KERNEL_SOURCE")"; then
      echo "Unsupported BOOT_KERNEL_SOURCE=$BOOT_KERNEL_SOURCE" >&2
      echo "Use pmos-snapshot or camera-package." >&2
      exit 1
    fi
  else
    INSTALL_KERNEL_TRACK="stable"
  fi
else
  if ! INSTALL_KERNEL_TRACK="$(normalize_kernel_track "$INSTALL_KERNEL_TRACK")"; then
    echo "Invalid INSTALL_KERNEL_TRACK=$INSTALL_KERNEL_TRACK" >&2
    echo "Use stable or camera." >&2
    exit 1
  fi
fi

apply_kernel_track "$INSTALL_KERNEL_TRACK"

if [[ -n "$INSTALL_APP_LAUNCHER_PACKAGE" && -z "$INSTALL_APP_LAUNCHER_COMMAND" ]]; then
  INSTALL_APP_LAUNCHER_PACKAGE="$(normalize_profile_package_name "$INSTALL_APP_LAUNCHER_PACKAGE")"
  INSTALL_APP_LAUNCHER_COMMAND="$(default_launcher_command_for_package "$INSTALL_APP_LAUNCHER_PACKAGE")"
fi

if ! valid_linux_username "$INSTALL_USERNAME"; then
  echo "Invalid INSTALL_USERNAME=$INSTALL_USERNAME" >&2
  exit 1
fi
INSTALL_APP_LAUNCHER_KEY="$(normalize_app_launcher_key "$INSTALL_APP_LAUNCHER_KEY")"
if ! valid_app_launcher_key "$INSTALL_APP_LAUNCHER_KEY"; then
  echo "Invalid INSTALL_APP_LAUNCHER_KEY=$INSTALL_APP_LAUNCHER_KEY" >&2
  echo "Use one letter that is not Q, H, C, or K. SUPER+1..0 are reserved for workspaces." >&2
  exit 1
fi
if [[ -n "$INSTALL_APP_LAUNCHER_PACKAGE" ]]; then
  INSTALL_APP_LAUNCHER_PACKAGE="$(normalize_profile_package_name "$INSTALL_APP_LAUNCHER_PACKAGE")"
  if ! valid_profile_package_name "$INSTALL_APP_LAUNCHER_PACKAGE"; then
    echo "Invalid INSTALL_APP_LAUNCHER_PACKAGE=$INSTALL_APP_LAUNCHER_PACKAGE" >&2
    exit 1
  fi
fi
if [[ -n "$INSTALL_APP_LAUNCHER_COMMAND" ]] && ! valid_launcher_command "$INSTALL_APP_LAUNCHER_COMMAND"; then
  echo "Invalid INSTALL_APP_LAUNCHER_COMMAND=$INSTALL_APP_LAUNCHER_COMMAND" >&2
  echo "Use a non-empty launcher command without commas or newlines." >&2
  exit 1
fi

if [[ -n "$INSTALL_BOOTANIMATION_ZIP" && ! -f "$INSTALL_BOOTANIMATION_ZIP" ]]; then
  echo "Invalid INSTALL_BOOTANIMATION_ZIP=$INSTALL_BOOTANIMATION_ZIP" >&2
  exit 1
fi

if [[ "$BOOT_KERNEL_SOURCE" == "camera-package" ]]; then
  if ! compgen -G "$ROOT_DIR/out/$PROFILE/packages/$CAMERA_KERNEL_PACKAGE_GLOB" >/dev/null; then
    cat >&2 <<EOF
Experimental camera kernel was selected, but no staged camera kernel package was found.

Expected:
  out/$PROFILE/packages/$CAMERA_KERNEL_PACKAGE_GLOB

Stable install path:
  INSTALL_KERNEL_TRACK=stable ./oneplus6t-install

Maintainer path:
  stage linux-oneplus6t-camera into out/$PROFILE/packages before choosing camera.
EOF
    exit 1
  fi
  cat <<'EOF'
Camera kernel warning:
  You selected the experimental IMX519/camera kernel track.
  This may crashdump or regress boot stability. Use it for testing, not recovery.
EOF
  echo
fi

case "$INSTALL_BOOT_VIDEO" in
  ""|bundled|Bundled|BUNDLED|default|Default|DEFAULT)
    INSTALL_BOOTANIMATION_ENABLE="${INSTALL_BOOTANIMATION_ENABLE:-1}"
    ;;
  none|None|NONE|no|No|NO|off|Off|OFF|verbose|Verbose|VERBOSE)
    INSTALL_BOOTANIMATION_ENABLE="0"
    INSTALL_BOOTANIMATION_ZIP=""
    ;;
  *)
    if [[ ! -f "$INSTALL_BOOT_VIDEO" ]]; then
      echo "Invalid INSTALL_BOOT_VIDEO=$INSTALL_BOOT_VIDEO" >&2
      echo "Use bundled/default, none/verbose, or a real video file path." >&2
      exit 1
    fi
    INSTALL_BOOTANIMATION_ENABLE="1"
    INSTALL_BOOTANIMATION_ZIP="$ROOT_DIR/work/$PROFILE/installer-bootanimation/bootanimation.zip"
    echo "Building custom boot animation from:"
    echo "  $INSTALL_BOOT_VIDEO"
    BOOTANIMATION_MAX_SECONDS="${BOOTANIMATION_MAX_SECONDS:-45}" \
      scripts/replace-boot-video.sh "$INSTALL_BOOT_VIDEO" "$INSTALL_BOOTANIMATION_ZIP"
    ;;
esac

INSTALL_BOOTANIMATION_ENABLE="${INSTALL_BOOTANIMATION_ENABLE:-1}"

export INSTALL_USERNAME
export INSTALL_WIFI_SSID
export INSTALL_WIFI_PASSWORD
export INSTALL_MOBILE_APN
export INSTALL_MOBILE_APN_USER
export INSTALL_MOBILE_APN_PASSWORD
export INSTALL_APP_LAUNCHER_PACKAGE
export INSTALL_APP_LAUNCHER_COMMAND
export INSTALL_APP_LAUNCHER_KEY
export INSTALL_BOOTANIMATION_ENABLE
export INSTALL_BOOTANIMATION_ZIP
export INSTALL_KERNEL_TRACK
export BOOT_KERNEL_SOURCE
export ENABLE_CAMERA_USERSPACE

echo "Image identity:"
echo "  username: $INSTALL_USERNAME"
case "$INSTALL_KERNEL_TRACK" in
  stable)
    echo "  kernel: stable PMOS 6.9 SDM845 snapshot"
    ;;
  camera)
    echo "  kernel: experimental IMX519 camera kernel"
    ;;
esac
if [[ -n "$INSTALL_WIFI_SSID" ]]; then
  echo "  Wi-Fi: configured for SSID '$INSTALL_WIFI_SSID'"
else
  echo "  Wi-Fi: not preconfigured"
fi
if [[ -n "$INSTALL_MOBILE_APN" ]]; then
  echo "  mobile APN: configured"
else
  echo "  mobile APN: not preconfigured"
fi
if [[ -n "$INSTALL_APP_LAUNCHER_COMMAND" ]]; then
  echo "  SUPER+$INSTALL_APP_LAUNCHER_KEY launcher: $INSTALL_APP_LAUNCHER_COMMAND"
  if [[ -n "$INSTALL_APP_LAUNCHER_PACKAGE" ]]; then
    echo "  launcher package: $INSTALL_APP_LAUNCHER_PACKAGE"
  fi
else
  echo "  SUPER-key launcher: not preconfigured"
fi
if [[ "$INSTALL_BOOTANIMATION_ENABLE" == "0" ]]; then
  echo "  boot intro: disabled, verbose boot visible"
elif [[ -n "$INSTALL_BOOTANIMATION_ZIP" ]]; then
  echo "  boot intro: custom video"
else
  echo "  boot intro: bundled video"
fi
echo

echo "== alpha access =="
if [[ "$ALLOW_INSECURE_DEFAULT_PASSWORD" == "1" ]]; then
  root_password_source="temporary default"
  user_password_source="temporary default"

  if [[ -v INSECURE_ROOT_PASSWORD ]]; then
    root_password_source="environment"
  else
    INSECURE_ROOT_PASSWORD="alarm"
  fi

  if [[ -v INSECURE_ALARM_PASSWORD ]]; then
    user_password_source="environment"
  else
    INSECURE_ALARM_PASSWORD="alarm"
  fi

  if password_prompt_is_allowed; then
    echo "Set local account passwords for this generated image."
    echo "Press Enter without typing a password to use the temporary default."
    [[ "$root_password_source" == "environment" ]] || \
      prompt_for_password "root SSH/su" INSECURE_ROOT_PASSWORD root_password_source
    [[ "$user_password_source" == "environment" ]] || \
      prompt_for_password "$INSTALL_USERNAME desktop/login" INSECURE_ALARM_PASSWORD user_password_source
  fi

  export INSECURE_ROOT_PASSWORD
  export INSECURE_ALARM_PASSWORD

  if [[ "$root_password_source" == "temporary default" || "$user_password_source" == "temporary default" ]]; then
    echo "Security notice: temporary default passwords are enabled because no custom password was entered."
    echo "  root SSH/su password: ${INSECURE_ROOT_PASSWORD}"
    echo "  $INSTALL_USERNAME desktop/login password: ${INSECURE_ALARM_PASSWORD}"
    echo "Please change both passwords to secure ones soon after the first boot."
  else
    echo "Using local account passwords supplied by ${root_password_source}/${user_password_source}."
    echo "You can change them later from the phone with passwd."
  fi
  echo "Set ALLOW_INSECURE_DEFAULT_PASSWORD=0 for SSH-key-only release builds."
else
  echo "Password login setup is disabled; use SSH keys or another access method."
fi
echo

echo "== fastboot visibility =="
echo "If no device is printed below, stop and put the phone in fastboot mode."
timeout "${FASTBOOT_PROBE_TIMEOUT_SECONDS:-3}s" fastboot devices -l || true
echo

echo "== live fastboot command check =="
echo "The installer will not use userdata-size fallback for destructive flashes."
wait_for_fastboot_ready "before package review and image build"
echo

if [[ "${INSTALL_PROFILE_PACKAGES:-1}" == "1" ]]; then
  echo "== profile package review =="
  reviewed_package_manifest="$(scripts/review-profile-packages.sh "$PROFILE")"
  export PACKAGE_MANIFEST="$reviewed_package_manifest"
  append_package_to_manifest "$PACKAGE_MANIFEST" "$INSTALL_APP_LAUNCHER_PACKAGE"
  echo "Using package manifest:"
  echo "  $PACKAGE_MANIFEST"
  echo
else
  echo "== profile package review =="
  echo "Skipping because INSTALL_PROFILE_PACKAGES=${INSTALL_PROFILE_PACKAGES:-1}."
  echo
fi

echo "== build full-userdata virtual root image =="
echo "The builder will set ROOT_IMAGE_SIZE from fastboot partition-size:userdata."
ALLOW_FASTBOOT_USERDATA_SIZE_FALLBACK=0 ROOT_IMAGE_SIZE_FROM_FASTBOOT=1 scripts/build-release.sh "$PROFILE"
echo

echo "== fastboot command re-check after build =="
wait_for_fastboot_ready "after root image build, before strict userdata preflight"
echo

echo "== strict userdata preflight =="
ALLOW_FASTBOOT_USERDATA_SIZE_FALLBACK=0 USERDATA_PREFLIGHT=strict scripts/fastboot-userdata-preflight.sh "$PROFILE"
echo

if [[ "${CONFIRM_FLASH:-0}" == "1" ]]; then
  answer="FLASH"
  echo "CONFIRM_FLASH=1 set; continuing without interactive FLASH prompt."
else
  echo "Ready to flash. This is destructive and replaces boot + userdata."
  read -r -p "Type FLASH to write boot + userdata now, or press Enter to stop: " answer
fi
answer="$(printf '%s' "$answer" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
if [[ "${answer^^}" != "FLASH" ]]; then
  echo "Stopped before flashing."
  exit 0
fi

echo
echo "== fastboot command re-check before flash =="
wait_for_fastboot_ready "immediately before destructive flash"
echo

echo "== flash =="
run_env_as_root \
  ALLOW_FASTBOOT_USERDATA_SIZE_FALLBACK=0 \
  CONFIRM_FLASH=1 \
  REBOOT_AFTER_FLASH="${REBOOT_AFTER_FLASH:-1}" \
  USERDATA_PREFLIGHT=strict \
  "$ROOT_DIR/scripts/flash-release.sh" "$PROFILE"
