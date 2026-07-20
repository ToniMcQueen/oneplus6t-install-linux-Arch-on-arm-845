#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${1:-oneplus-fajita}"
PROFILE_DIR="$ROOT_DIR/profiles/$PROFILE"

if [[ ! -f "$PROFILE_DIR/config.env" ]]; then
  echo "Missing profile config: $PROFILE_DIR/config.env" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$PROFILE_DIR/config.env"

# shellcheck source=scripts/package-name-aliases.sh
source "$ROOT_DIR/scripts/package-name-aliases.sh"

OUT_DIR="${OUT_DIR:-$ROOT_DIR/out/$PROFILE}"
CACHE_DIR="${CACHE_DIR:-$ROOT_DIR/cache}"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/work/$PROFILE/rootfs}"
MNT_DIR="$WORK_DIR/mnt"
RAW_IMG="$OUT_DIR/oneplus6t-arch-root.raw.img"
SPARSE_IMG="$OUT_DIR/oneplus6t-arch-root.img"
ROOTFS_TARBALL="${ARCH_ROOTFS_TARBALL:-$CACHE_DIR/ArchLinuxARM-aarch64-latest.tar.gz}"
BTRFS_MKFS_FEATURES="${BTRFS_MKFS_FEATURES:-}"
PACKAGE_MANIFEST="${PACKAGE_MANIFEST:-$PROFILE_DIR/packages.txt}"
CAMERA_PACKAGE_MANIFEST="${CAMERA_PACKAGE_MANIFEST:-$PROFILE_DIR/camera-packages.txt}"
INSTALL_PROFILE_PACKAGES="${INSTALL_PROFILE_PACKAGES:-1}"
ENABLE_CAMERA_USERSPACE="${ENABLE_CAMERA_USERSPACE:-0}"
INSTALL_USERNAME="${INSTALL_USERNAME:-alarm}"
INSTALL_WIFI_SSID="${INSTALL_WIFI_SSID:-}"
INSTALL_WIFI_PASSWORD="${INSTALL_WIFI_PASSWORD:-}"
INSTALL_MOBILE_APN="${INSTALL_MOBILE_APN:-}"
INSTALL_MOBILE_APN_USER="${INSTALL_MOBILE_APN_USER:-}"
INSTALL_MOBILE_APN_PASSWORD="${INSTALL_MOBILE_APN_PASSWORD:-}"
INSTALL_APP_LAUNCHER_PACKAGE="${INSTALL_APP_LAUNCHER_PACKAGE:-}"
INSTALL_APP_LAUNCHER_COMMAND="${INSTALL_APP_LAUNCHER_COMMAND:-}"
INSTALL_APP_LAUNCHER_KEY="${INSTALL_APP_LAUNCHER_KEY:-S}"
INSTALL_BOOTANIMATION_ENABLE="${INSTALL_BOOTANIMATION_ENABLE:-1}"
INSTALL_BOOTANIMATION_ZIP="${INSTALL_BOOTANIMATION_ZIP:-}"
PACMAN_CACHE_DIR="${PACMAN_CACHE_DIR:-$CACHE_DIR/alarm-packages/pkg}"
PACMAN_CONF="$WORK_DIR/pacman-aarch64.conf"
PACMAN_LOG="$WORK_DIR/pacman-rootfs.log"
PACMAN_HOOK_DIR="$WORK_DIR/empty-hooks"
PMOS_COMPAT_PAYLOAD_DIR="${PMOS_COMPAT_PAYLOAD_DIR:-}"
PMOS_HARDWARE_REFERENCE_TARBALL="${PMOS_HARDWARE_REFERENCE_TARBALL:-}"
LOCAL_PACKAGE_DIR="${LOCAL_PACKAGE_DIR:-$OUT_DIR/packages}"
WVKBD_SOURCE_CACHE_DIR="${WVKBD_SOURCE_CACHE_DIR:-$ROOT_DIR/vendor/wvkbd}"
WVKBD_REF="${WVKBD_REF:-4fd182a58385b4754756e6dc66860e9ff601b3a1}"
HYPERROTATION_SOURCE_CACHE_DIR="${HYPERROTATION_SOURCE_CACHE_DIR:-$ROOT_DIR/vendor/hyperrotation}"
HYPERROTATION_REF="${HYPERROTATION_REF:-38606861f25a2aec1eaefae38f3bcb8d0c332972}"

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "This script must run as root because it creates and mounts a filesystem image." >&2
    echo "Use doas or sudo from the project root." >&2
    exit 1
  fi
}

require_tools() {
  local missing=0
  for tool in curl tar truncate mkfs.btrfs mount umount findmnt sha256sum rsync; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "Missing required tool: $tool" >&2
      missing=1
    fi
  done
  if [[ "$INSTALL_PROFILE_PACKAGES" == "1" || -d "$LOCAL_PACKAGE_DIR" ]] && ! command -v pacman >/dev/null 2>&1; then
    echo "Missing required tool: pacman" >&2
    missing=1
  fi
  [[ "$missing" -eq 0 ]] || exit 1
}

download_rootfs() {
  mkdir -p "$CACHE_DIR"
  if [[ -f "$ROOTFS_TARBALL" ]]; then
    echo "Using cached/rootfs tarball: $ROOTFS_TARBALL"
    return
  fi
  echo "Downloading Arch Linux ARM rootfs:"
  echo "$ARCHLINUXARM_ROOTFS_URL"
  curl -L --fail --output "$ROOTFS_TARBALL" "$ARCHLINUXARM_ROOTFS_URL"
}

validate_pmos_boot_files() {
  local missing=0
  local file

  for file in "$PMOS_INITRAMFS" "$PMOS_INITRAMFS_EXTRA"; do
    if [[ ! -f "$PMOS_BOOT_DIR/$file" ]]; then
      echo "Missing PMOS boot artifact: $PMOS_BOOT_DIR/$file" >&2
      missing=1
    fi
  done

  if [[ "${BOOT_KERNEL_SOURCE:-pmos-snapshot}" == "pmos-snapshot" ]]; then
    for file in "$PMOS_KERNEL" "$PMOS_DTB"; do
      if [[ ! -f "$PMOS_BOOT_DIR/$file" ]]; then
        echo "Missing PMOS boot artifact: $PMOS_BOOT_DIR/$file" >&2
        missing=1
      fi
    done
  fi

  if [[ "$missing" -ne 0 ]]; then
    cat >&2 <<EOF

Place the working PMOS boot artifacts in:
  $PMOS_BOOT_DIR

For local low-space builds, symlink that directory instead of copying it.
EOF
    exit 1
  fi
}

cleanup_mount() {
  if mountpoint -q "$MNT_DIR"; then
    umount "$MNT_DIR"
  fi
}

apply_overlay() {
  local overlay="$PROFILE_DIR/overlay"
  if [[ -d "$overlay" ]]; then
    rsync -a --no-owner --no-group "$overlay"/ "$MNT_DIR"/
  fi
}

install_pmos_compat_payload() {
  if [[ -z "$PMOS_COMPAT_PAYLOAD_DIR" || ! -d "$PMOS_COMPAT_PAYLOAD_DIR" ]]; then
    echo "No PMOS compatibility payload found; Wi-Fi/modem helper services will not be installed."
    return
  fi

  echo "Installing local PMOS compatibility payload:"
  echo "  $PMOS_COMPAT_PAYLOAD_DIR"
  rsync -a "$PMOS_COMPAT_PAYLOAD_DIR"/ "$MNT_DIR"/
}

install_pmos_hardware_reference() {
  local tmp

  if [[ -z "$PMOS_HARDWARE_REFERENCE_TARBALL" || ! -f "$PMOS_HARDWARE_REFERENCE_TARBALL" ]]; then
    echo "No PMOS hardware reference archive found; matching kernel modules/firmware will not be installed."
    return
  fi

  echo "Installing local PMOS hardware reference:"
  echo "  $PMOS_HARDWARE_REFERENCE_TARBALL"

  tmp="$(mktemp -d "$WORK_DIR/pmos-hw.XXXXXX")"
  if [[ "${BOOT_KERNEL_SOURCE:-pmos-snapshot}" == "camera-package" ]]; then
    tar -C "$tmp" -xf "$PMOS_HARDWARE_REFERENCE_TARBALL" lib/firmware
  else
    tar -C "$tmp" -xf "$PMOS_HARDWARE_REFERENCE_TARBALL" \
      lib/modules/6.9.0-sdm845 \
      lib/firmware
  fi

  mkdir -p "$MNT_DIR/usr/lib/modules" "$MNT_DIR/usr/lib/firmware"
  if [[ -d "$tmp/lib/modules" ]]; then
    rsync -a "$tmp/lib/modules"/ "$MNT_DIR/usr/lib/modules"/
  fi
  rsync -a "$tmp/lib/firmware"/ "$MNT_DIR/usr/lib/firmware"/
  chown -R 0:0 "$MNT_DIR/usr/lib/firmware"
  if [[ -d "$MNT_DIR/usr/lib/modules/6.9.0-sdm845" ]]; then
    chown -R 0:0 "$MNT_DIR/usr/lib/modules/6.9.0-sdm845"
  fi
}

install_source_cache() {
  local name="$1"
  local source_dir="$2"
  local ref="$3"
  local dest="$MNT_DIR/var/cache/oneplus6t/$name"

  if [[ ! -d "$source_dir" || ! -f "$source_dir/Makefile" ]]; then
    echo "No $name source cache found; first-boot service will clone if network is available."
    echo "  $source_dir"
    return
  fi

  echo "Installing $name source cache:"
  echo "  $source_dir -> $dest"
  mkdir -p "$dest"
  rsync -a --delete \
    --exclude .git \
    --exclude build \
    --exclude '*.o' \
    --exclude '*.so' \
    --exclude src/git_info.hpp \
    "$source_dir"/ "$dest"/
  printf '%s\n' "$ref" > "$dest/.oneplus6t-source-ref"
  chown -R 0:0 "$dest"
}

enable_system_unit() {
  local unit="$1"
  local target="${2:-multi-user.target}"
  local unit_path

  mkdir -p "$MNT_DIR/etc/systemd/system/$target.wants"

  for unit_path in \
    "$MNT_DIR/etc/systemd/system/$unit" \
    "$MNT_DIR/usr/lib/systemd/system/$unit"; do
    if [[ -f "$unit_path" ]]; then
      ln -sf "${unit_path#"$MNT_DIR"}" \
        "$MNT_DIR/etc/systemd/system/$target.wants/$unit"
      return
    fi
  done
}

mask_system_unit() {
  local unit="$1"

  rm -f \
    "$MNT_DIR/etc/systemd/system/sysinit.target.wants/$unit" \
    "$MNT_DIR/etc/systemd/system/multi-user.target.wants/$unit" \
    "$MNT_DIR/etc/systemd/system/default.target.wants/$unit" \
    "$MNT_DIR/etc/systemd/system/graphical.target.wants/$unit"
  mkdir -p "$MNT_DIR/etc/systemd/system"
  ln -sfn /dev/null "$MNT_DIR/etc/systemd/system/$unit"
}

configure_sensor_units() {
  local unit
  local sensor_units=(
    hexagonrpcd-sdsp.service
    hexagonrpcd-adsp-rootpd.service
    hexagonrpcd-adsp-sensorspd.service
    iio-sensor-proxy.service
  )

  if [[ "${ENABLE_HEXAGON_SENSORS:-1}" != "1" ]]; then
    echo "Masking Hexagon/IIO sensor services for recovery boot."
    for unit in "${sensor_units[@]}"; do
      mask_system_unit "$unit"
    done
    return
  fi

  echo "Enabling PMOS-style Hexagon sensor boot path."
  enable_system_unit hexagonrpcd-sdsp.service sysinit.target
  enable_system_unit iio-sensor-proxy.service multi-user.target

  # The ADSP fallback units are useful for manual lab work only. They are not
  # part of the PMOS-style boot path and have been involved in crashdump loops.
  for unit in hexagonrpcd-adsp-rootpd.service hexagonrpcd-adsp-sensorspd.service; do
    mask_system_unit "$unit"
  done
}

configure_pmos_compat_units() {
  local unit
  local wanted_by
  local units=(
    pmos-compat-tqftpserv.service
    pmos-compat-rmtfs.service
    pmos-compat-pd-mapper.service
  )

  if [[ "${ENABLE_PMOS_COMPAT_UNITS:-1}" != "1" ]]; then
    echo "Masking PMOS compatibility services for recovery boot."
    for unit in "${units[@]}"; do
      mask_system_unit "$unit"
    done
    return
  fi

  for unit in "${units[@]}"; do
    if [[ ! -f "$MNT_DIR/etc/systemd/system/$unit" && ! -f "$MNT_DIR/usr/lib/systemd/system/$unit" ]]; then
      continue
    fi

    mkdir -p "$MNT_DIR/etc/systemd/system/$unit.d"

    if [[ "$unit" == "pmos-compat-rmtfs.service" ]]; then
      cat > "$MNT_DIR/etc/systemd/system/$unit.d/10-oneplus6t-radio.conf" <<'EOF'
[Unit]
DefaultDependencies=no
After=systemd-udevd.service systemd-udev-trigger.service systemd-modules-load.service pmos-compat-tqftpserv.service
Before=NetworkManager.service ModemManager.service

[Service]
ExecStart=
ExecStart=/opt/pmos-compat/sbin/rmtfs -P -r -s
EOF
      rm -f "$MNT_DIR/etc/systemd/system/sysinit.target.wants/$unit"
      continue
    fi

    cat > "$MNT_DIR/etc/systemd/system/$unit.d/10-oneplus6t-early.conf" <<'EOF'
[Unit]
DefaultDependencies=no
After=systemd-udevd.service systemd-udev-trigger.service systemd-modules-load.service
Before=sysinit.target oneplus6t-qcom-remoteproc.service NetworkManager.service ModemManager.service
EOF

    wanted_by=sysinit.target
    enable_system_unit "$unit" "$wanted_by"
  done
}

ensure_hyprland_profile_includes() {
  local conf="$MNT_DIR/home/$INSTALL_USERNAME/.config/hypr/hyprland.conf"
  local include_line="source = ~/.config/hypr/conf.d/*.conf"

  if [[ ! -f "$conf" ]]; then
    return
  fi

  if ! grep -Fxq "$include_line" "$conf"; then
    {
      printf '\n'
      printf '# OnePlus 6T profile includes\n'
      printf '%s\n' "$include_line"
    } >> "$conf"
  fi
}

valid_linux_username() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

configure_installer_identity() {
  local username="$INSTALL_USERNAME"
  local old_home="$MNT_DIR/home/alarm"
  local new_home="$MNT_DIR/home/$username"
  local file

  if ! valid_linux_username "$username"; then
    echo "Invalid INSTALL_USERNAME=$username" >&2
    exit 1
  fi

  if [[ "$username" != "alarm" ]]; then
    echo "Renaming default desktop user alarm -> $username."

    awk -F: -v "username=$username" '
      BEGIN { OFS = ":" }
      $1 == "alarm" {
        $1 = username
        $6 = "/home/" username
      }
      { print }
    ' "$MNT_DIR/etc/passwd" > "$MNT_DIR/etc/passwd.new"
    mv "$MNT_DIR/etc/passwd.new" "$MNT_DIR/etc/passwd"

    awk -F: -v "username=$username" '
      BEGIN { OFS = ":" }
      $1 == "alarm" { $1 = username }
      { print }
    ' "$MNT_DIR/etc/shadow" > "$MNT_DIR/etc/shadow.new"
    mv "$MNT_DIR/etc/shadow.new" "$MNT_DIR/etc/shadow"
    chmod 000 "$MNT_DIR/etc/shadow"

    for file in "$MNT_DIR/etc/group" "$MNT_DIR/etc/gshadow"; do
      [[ -f "$file" ]] || continue
      awk -F: -v "username=$username" '
        BEGIN { OFS = ":" }
        $1 == "alarm" { $1 = username }
        {
          n = split($4, members, ",")
          for (idx = 1; idx <= n; idx++) {
            if (members[idx] == "alarm") {
              members[idx] = username
            }
          }
          if ($4 != "") {
            $4 = members[1]
            for (idx = 2; idx <= n; idx++) {
              $4 = $4 "," members[idx]
            }
          }
          print
        }
      ' "$file" > "$file.new"
      mv "$file.new" "$file"
    done

    if [[ -d "$old_home" ]]; then
      rm -rf "$new_home"
      mv "$old_home" "$new_home"
    fi

    for file in \
      "$MNT_DIR/etc/doas.conf" \
      "$MNT_DIR/etc/systemd/system/getty@tty1.service.d/10-oneplus6t-autologin.conf" \
      "$MNT_DIR/etc/systemd/system/oneplus6t-hyperrotation-build.service"; do
      [[ -f "$file" ]] || continue
      sed -i \
        -e "s#/home/alarm#/home/$username#g" \
        -e "s/--autologin alarm/--autologin $username/g" \
        -e "s/permit nopass alarm cmd chvt/permit nopass $username cmd chvt/g" \
        "$file"
    done
  fi
}

write_installer_wifi_config() {
  if [[ -z "$INSTALL_WIFI_SSID" ]]; then
    return
  fi

  echo "Installing NetworkManager Wi-Fi profile for the requested SSID."
  install -d -m 0700 "$MNT_DIR/etc/NetworkManager/system-connections"
  {
    cat <<EOF
[connection]
id=oneplus6t-wifi
uuid=11111111-1111-4111-8111-111111111111
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=$INSTALL_WIFI_SSID

EOF
    if [[ -n "$INSTALL_WIFI_PASSWORD" ]]; then
      cat <<EOF
[wifi-security]
key-mgmt=wpa-psk
psk=$INSTALL_WIFI_PASSWORD

EOF
    fi
    cat <<'EOF'
[ipv4]
method=auto

[ipv6]
method=auto
EOF
  } > "$MNT_DIR/etc/NetworkManager/system-connections/oneplus6t-wifi.nmconnection"
  chown 0:0 "$MNT_DIR/etc/NetworkManager/system-connections/oneplus6t-wifi.nmconnection"
  chmod 0600 "$MNT_DIR/etc/NetworkManager/system-connections/oneplus6t-wifi.nmconnection"
}

write_installer_mobile_apn_config() {
  if [[ -z "$INSTALL_MOBILE_APN" ]]; then
    return
  fi

  echo "Installing mobile-data APN configuration."
  {
    cat <<'EOF'
# OnePlus 6T mobile data helper configuration.
#
# Written by the installer from optional APN setup.

EOF
    printf 'AUTO_CONNECT=%q\n' "yes"
    printf 'APN=%q\n' "$INSTALL_MOBILE_APN"
    printf 'APN_USER=%q\n' "$INSTALL_MOBILE_APN_USER"
    printf 'APN_PASSWORD=%q\n' "$INSTALL_MOBILE_APN_PASSWORD"
    printf 'IP_TYPE=%q\n' "ipv4"
    printf 'ROUTE_METRIC=%q\n' "700"
    printf 'CONNECT_TIMEOUT=%q\n' "60"
    printf 'ALLOW_EMPTY_APN=%q\n' "no"
  } > "$MNT_DIR/etc/oneplus6t-mobile-data.conf"
  chown 0:0 "$MNT_DIR/etc/oneplus6t-mobile-data.conf"
  chmod 0600 "$MNT_DIR/etc/oneplus6t-mobile-data.conf"
}

write_installer_app_launcher_config() {
  local conf_dir="$MNT_DIR/home/$INSTALL_USERNAME/.config/hypr/conf.d"
  local conf="$conf_dir/20-installer-app-launcher.conf"
  local launcher_key="${INSTALL_APP_LAUNCHER_KEY^^}"

  if [[ -z "$INSTALL_APP_LAUNCHER_COMMAND" ]]; then
    return
  fi

  if [[ "$INSTALL_APP_LAUNCHER_COMMAND" == *$'\n'* || \
        "$INSTALL_APP_LAUNCHER_COMMAND" == *$'\r'* || \
        "$INSTALL_APP_LAUNCHER_COMMAND" == *","* ]]; then
    echo "Invalid INSTALL_APP_LAUNCHER_COMMAND=$INSTALL_APP_LAUNCHER_COMMAND" >&2
    echo "Use a non-empty launcher command without commas or newlines." >&2
    exit 1
  fi

  if [[ ! "$launcher_key" =~ ^[A-Z]$ ]]; then
    echo "Invalid INSTALL_APP_LAUNCHER_KEY=$INSTALL_APP_LAUNCHER_KEY" >&2
    echo "Use one launcher letter that is not already bound by the phone profile." >&2
    exit 1
  fi

  case "$launcher_key" in
    Q|H|C|K)
      echo "Invalid INSTALL_APP_LAUNCHER_KEY=$INSTALL_APP_LAUNCHER_KEY" >&2
      echo "Reserved keys: SUPER+Q terminal, SUPER+H keyboard kill, SUPER+C close, SUPER+K keyboard toggle, SUPER+1..0 workspaces." >&2
      exit 1
      ;;
  esac

  echo "Installing optional SUPER+$launcher_key app launcher binding."
  install -d -m 0755 "$conf_dir"
  {
    cat <<'EOF'
# Generated by the installer when the user opts into an app launcher.
# The base image deliberately leaves app-launcher keys unbound.
EOF
    if [[ -n "$INSTALL_APP_LAUNCHER_PACKAGE" ]]; then
      printf '# Requested package: %s\n' "$INSTALL_APP_LAUNCHER_PACKAGE"
    fi
    printf 'bind = SUPER, %s, exec, %s\n' "$launcher_key" "$INSTALL_APP_LAUNCHER_COMMAND"
  } > "$conf"
}

configure_bootanimation() {
  local target_zip="$MNT_DIR/usr/share/oneplus6t/bootanimation.zip"

  case "$INSTALL_BOOTANIMATION_ENABLE" in
    1|true|True|TRUE|yes|Yes|YES)
      if [[ -n "$INSTALL_BOOTANIMATION_ZIP" ]]; then
        if [[ ! -f "$INSTALL_BOOTANIMATION_ZIP" ]]; then
          echo "Missing requested bootanimation zip: $INSTALL_BOOTANIMATION_ZIP" >&2
          exit 1
        fi
        echo "Installing custom boot animation."
        install -D -m 0644 "$INSTALL_BOOTANIMATION_ZIP" "$target_zip"
      else
        echo "Using bundled boot animation."
      fi
      enable_system_unit oneplus6t-bootanimation.service
      ;;
    0|false|False|FALSE|no|No|NO|none|verbose)
      echo "Disabling boot animation so verbose boot remains visible."
      rm -f "$target_zip"
      mask_system_unit oneplus6t-bootanimation.service
      ;;
    *)
      echo "Invalid INSTALL_BOOTANIMATION_ENABLE=$INSTALL_BOOTANIMATION_ENABLE" >&2
      exit 1
      ;;
  esac
}

fix_profile_ownership() {
  chown -h 0:0 "$MNT_DIR"
  chmod 0755 "$MNT_DIR"

  local root_path
  for root_path in bin boot dev etc lib lib64 mnt opt proc root run sbin srv sys tmp usr var; do
    if [[ -e "$MNT_DIR/$root_path" || -L "$MNT_DIR/$root_path" ]]; then
      chown -h 0:0 "$MNT_DIR/$root_path"
    fi
  done

  for root_path in boot etc opt root srv usr var; do
    if [[ -e "$MNT_DIR/$root_path" ]]; then
      chown -R 0:0 "$MNT_DIR/$root_path"
    fi
  done

  [[ -d "$MNT_DIR/tmp" ]] && chmod 1777 "$MNT_DIR/tmp"

  if [[ -d "$MNT_DIR/home/$INSTALL_USERNAME" ]]; then
    chown -R 1000:1000 "$MNT_DIR/home/$INSTALL_USERNAME"
  fi
  if [[ -d "$MNT_DIR/usr/local/bin" ]]; then
    chmod 0755 "$MNT_DIR/usr/local/bin"/oneplus6t-* 2>/dev/null || true
  fi
  if [[ -d "$MNT_DIR/usr/local/sbin" ]]; then
    chmod 0755 "$MNT_DIR/usr/local/sbin"/oneplus6t-* 2>/dev/null || true
  fi
  for unit in \
    oneplus6t-power-key-inhibit.service \
    oneplus6t-uim-select.service \
    oneplus6t-mobile-data.service \
    oneplus6t-bluetooth-address.service \
    oneplus6t-pacman-keyring.service \
    oneplus6t-cpu-power.service \
    oneplus6t-root-resize.service \
    oneplus6t-wvkbd-build.service \
    oneplus6t-hyperrotation-build.service \
    oneplus6t-keychords.service \
    oneplus6t-touch-osk.service; do
    enable_system_unit "$unit"
  done

  configure_bootanimation

  if [[ "${ENABLE_QCOM_REMOTEPROC:-1}" == "1" ]]; then
    echo "Enabling early Qualcomm remoteproc module service."
    enable_system_unit oneplus6t-qcom-remoteproc.service sysinit.target
  else
    echo "Masking early Qualcomm remoteproc module service for recovery boot."
    mask_system_unit oneplus6t-qcom-remoteproc.service
  fi
  if [[ "${ENABLE_QCOM_RADIO:-0}" == "1" ]]; then
    echo "Enabling delayed Qualcomm radio remoteproc service."
    enable_system_unit oneplus6t-qcom-radio.service multi-user.target
  else
    echo "Leaving delayed Qualcomm radio remoteproc service disabled."
    mask_system_unit oneplus6t-qcom-radio.service
  fi
  if [[ "${ENABLE_QCOM_WIFI:-0}" == "1" ]]; then
    echo "Enabling late Qualcomm Wi-Fi remoteproc service."
    enable_system_unit oneplus6t-wifi-remoteproc.service multi-user.target
  else
    echo "Leaving late Qualcomm Wi-Fi remoteproc service disabled."
    mask_system_unit oneplus6t-wifi-remoteproc.service
  fi
  configure_pmos_compat_units
  configure_sensor_units

  for unit in NetworkManager.service bluetooth.service ModemManager.service upower.service rtkit-daemon.service; do
    enable_system_unit "$unit"
  done
  echo "Masking networkd wait-online; NetworkManager owns connectivity on this profile."
  mask_system_unit systemd-networkd-wait-online.service

  mkdir -p "$MNT_DIR/etc/systemd/user/default.target.wants" \
    "$MNT_DIR/etc/systemd/user/sockets.target.wants" \
    "$MNT_DIR/etc/systemd/user/pipewire.service.wants"

  for unit in pipewire.service pipewire-pulse.service; do
    if [[ -f "$MNT_DIR/usr/lib/systemd/user/$unit" ]]; then
      ln -sf "/usr/lib/systemd/user/$unit" \
        "$MNT_DIR/etc/systemd/user/default.target.wants/$unit"
    fi
  done

  for socket in pipewire.socket pipewire-pulse.socket; do
    if [[ -f "$MNT_DIR/usr/lib/systemd/user/$socket" ]]; then
      ln -sf "/usr/lib/systemd/user/$socket" \
        "$MNT_DIR/etc/systemd/user/sockets.target.wants/$socket"
    fi
  done

  if [[ -f "$MNT_DIR/usr/lib/systemd/user/wireplumber.service" ]]; then
    ln -sf /usr/lib/systemd/user/wireplumber.service \
      "$MNT_DIR/etc/systemd/user/default.target.wants/wireplumber.service"
    ln -sf /usr/lib/systemd/user/wireplumber.service \
      "$MNT_DIR/etc/systemd/user/pipewire.service.wants/wireplumber.service"
    ln -sf /usr/lib/systemd/user/wireplumber.service \
      "$MNT_DIR/etc/systemd/user/pipewire-session-manager.service"
  fi
}

fix_privileged_helper_modes() {
  local helper

  for helper in usr/bin/su usr/bin/doas; do
    if [[ -e "$MNT_DIR/$helper" ]]; then
      chown 0:0 "$MNT_DIR/$helper"
      chmod 4755 "$MNT_DIR/$helper"
    fi
  done
}

enable_insecure_password_if_requested() {
  if [[ "$ALLOW_INSECURE_DEFAULT_PASSWORD" != "1" ]]; then
    return
  fi

  local root_password="${INSECURE_ROOT_PASSWORD:-alarm}"
  local user_password="${INSECURE_ALARM_PASSWORD:-alarm}"
  local username="$INSTALL_USERNAME"
  local root_hash user_hash

  if [[ "$root_password" == "alarm" || "$user_password" == "alarm" ]]; then
    echo "Security notice: temporary default passwords are enabled because no custom password was entered."
    echo "Please change both passwords to secure ones soon after the first boot."
  else
    echo "Security notice: enabling installer-selected local passwords for root and $username."
  fi
  root_hash="$(openssl passwd -6 "$root_password")"
  user_hash="$(openssl passwd -6 "$user_password")"
  awk -F: -v "root_hash=$root_hash" -v "user_hash=$user_hash" -v "username=$username" '
    BEGIN { OFS = ":" }
    $1 == "root" { $2 = root_hash }
    $1 == username { $2 = user_hash }
    { print }
  ' \
    "$MNT_DIR/etc/shadow" > "$MNT_DIR/etc/shadow.new"
  mv "$MNT_DIR/etc/shadow.new" "$MNT_DIR/etc/shadow"
  chmod 000 "$MNT_DIR/etc/shadow"

  if [[ -f "$MNT_DIR/etc/group" ]]; then
    awk -F: -v "username=$username" '
      BEGIN { OFS = ":"; found = 0 }
      $1 == "wheel" {
        found = 1
        split($4, members, ",")
        has_user = 0
        for (idx in members) {
          if (members[idx] == username) {
            has_user = 1
          }
        }
        if (!has_user) {
          $4 = ($4 == "" ? username : $4 "," username)
        }
      }
      { print }
      END {
        if (!found) {
          print "wheel:x:998:" username
        }
      }
    ' "$MNT_DIR/etc/group" > "$MNT_DIR/etc/group.new"
    mv "$MNT_DIR/etc/group.new" "$MNT_DIR/etc/group"
    chmod 0644 "$MNT_DIR/etc/group"
  fi

  mkdir -p "$MNT_DIR/etc/ssh/sshd_config.d"
  cat > "$MNT_DIR/etc/ssh/sshd_config.d/90-linuxphone-dev.conf" <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
EOF
}

enable_sshd_service() {
  if [[ ! -x "$MNT_DIR/usr/bin/sshd" ]]; then
    echo "OpenSSH server binary missing from root image: /usr/bin/sshd" >&2
    echo "Add openssh to the profile package manifest before building." >&2
    exit 1
  fi
  if [[ ! -f "$MNT_DIR/usr/lib/systemd/system/sshd.service" ]]; then
    echo "OpenSSH systemd unit missing from root image: /usr/lib/systemd/system/sshd.service" >&2
    echo "Add openssh to the profile package manifest before building." >&2
    exit 1
  fi

  mkdir -p "$MNT_DIR/etc/systemd/system/multi-user.target.wants"
  ln -sf /usr/lib/systemd/system/sshd.service \
    "$MNT_DIR/etc/systemd/system/multi-user.target.wants/sshd.service"
}

install_ssh_onboarding() {
  local key_tmp="$WORK_DIR/authorized_keys.input"
  local key_clean="$WORK_DIR/authorized_keys.clean"
  local key_file

  : > "$key_tmp"

  if [[ -n "${SSH_AUTHORIZED_KEYS:-}" ]]; then
    printf '%s\n' "$SSH_AUTHORIZED_KEYS" >> "$key_tmp"
  fi

  if [[ -n "${SSH_AUTHORIZED_KEYS_FILE:-}" ]]; then
    if [[ ! -f "$SSH_AUTHORIZED_KEYS_FILE" ]]; then
      echo "Configured SSH_AUTHORIZED_KEYS_FILE does not exist: $SSH_AUTHORIZED_KEYS_FILE" >&2
      exit 1
    fi
    cat "$SSH_AUTHORIZED_KEYS_FILE" >> "$key_tmp"
  fi

  if [[ -n "${SSH_AUTHORIZED_KEYS_GLOB:-}" ]]; then
    while IFS= read -r key_file; do
      cat "$key_file" >> "$key_tmp"
    done < <(compgen -G "$SSH_AUTHORIZED_KEYS_GLOB" | sort || true)
  fi

  awk '
    /^[[:space:]]*($|#)/ { next }
    /^(ssh|ecdsa|sk)-[A-Za-z0-9@._+-]+[[:space:]]/ && !seen[$0]++ { print }
  ' "$key_tmp" > "$key_clean"

  if [[ ! -s "$key_clean" ]]; then
    cat >&2 <<EOF
No SSH authorized keys were configured.
Set SSH_AUTHORIZED_KEYS_FILE, SSH_AUTHORIZED_KEYS_GLOB, or SSH_AUTHORIZED_KEYS
for SSH-key onboarding. Password SSH hardening was not applied.
EOF
    return
  fi

  install -d -m 0700 "$MNT_DIR/home/$INSTALL_USERNAME/.ssh"
  install -m 0600 "$key_clean" "$MNT_DIR/home/$INSTALL_USERNAME/.ssh/authorized_keys"
  chown -R 1000:1000 "$MNT_DIR/home/$INSTALL_USERNAME/.ssh"

  if [[ "${INSTALL_ROOT_SSH_KEYS:-0}" == "1" ]]; then
    install -d -m 0700 "$MNT_DIR/root/.ssh"
    install -m 0600 "$key_clean" "$MNT_DIR/root/.ssh/authorized_keys"
    chown -R 0:0 "$MNT_DIR/root/.ssh"
  fi

  if [[ "${DISABLE_SSH_PASSWORD_AUTH:-1}" == "1" ]]; then
    mkdir -p "$MNT_DIR/etc/ssh/sshd_config.d"
    cat > "$MNT_DIR/etc/ssh/sshd_config.d/80-oneplus6t-ssh-keys.conf" <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
  fi
}

install_pmos_boot_files() {
  mkdir -p "$MNT_DIR/boot/pmos-current"
  cp -a "$PMOS_BOOT_DIR/$PMOS_INITRAMFS" "$MNT_DIR/boot/initramfs"
  cp -a "$PMOS_BOOT_DIR/$PMOS_INITRAMFS_EXTRA" "$MNT_DIR/boot/initramfs-extra"
  if [[ "${BOOT_KERNEL_SOURCE:-pmos-snapshot}" == "camera-package" ]]; then
    if [[ ! -f "$MNT_DIR/boot/vmlinuz-oneplus6t-camera" || \
          ! -f "$MNT_DIR/boot/dtbs/qcom/sdm845-oneplus-fajita.dtb" ]]; then
      echo "Camera kernel package did not install its kernel and fajita DTB." >&2
      exit 1
    fi
    cp -a "$MNT_DIR/boot/vmlinuz-oneplus6t-camera" "$MNT_DIR/boot/vmlinuz"
    cp -a "$MNT_DIR/boot/dtbs/qcom/sdm845-oneplus-fajita.dtb" \
      "$MNT_DIR/boot/sdm845-oneplus-fajita.dtb"
  else
    cp -a "$PMOS_BOOT_DIR/$PMOS_KERNEL" "$MNT_DIR/boot/vmlinuz"
    cp -a "$PMOS_BOOT_DIR/$PMOS_DTB" "$MNT_DIR/boot/sdm845-oneplus-fajita.dtb"
  fi
  [[ -f "$PMOS_BOOT_DIR/linux.efi" ]] && cp -a "$PMOS_BOOT_DIR/linux.efi" "$MNT_DIR/boot/linux.efi"
  cp -a "$PMOS_BOOT_DIR"/. "$MNT_DIR/boot/pmos-current/"
}

read_package_manifest() {
  if [[ ! -f "$PACKAGE_MANIFEST" ]]; then
    echo "Missing package manifest: $PACKAGE_MANIFEST" >&2
    exit 1
  fi

  local manifests=("$PACKAGE_MANIFEST")
  if [[ "$ENABLE_CAMERA_USERSPACE" == "1" ]]; then
    if [[ ! -f "$CAMERA_PACKAGE_MANIFEST" ]]; then
      echo "Missing camera package manifest: $CAMERA_PACKAGE_MANIFEST" >&2
      exit 1
    fi
    manifests+=("$CAMERA_PACKAGE_MANIFEST")
  fi

  mapfile -t PROFILE_PACKAGES < <(awk '
    /^[[:space:]]*($|#)/ { next }
    { print $1 }
  ' "${manifests[@]}" | while IFS= read -r package; do
    normalize_profile_package_name "$package"
  done | awk '!seen[$1]++ { print $1 }')
}

require_camera_kernel_package() {
  if [[ "${BOOT_KERNEL_SOURCE:-pmos-snapshot}" != "camera-package" ]]; then
    return
  fi

  if ! find "$LOCAL_PACKAGE_DIR" -maxdepth 1 \( -type f -o -type l \) \
    -name "$CAMERA_KERNEL_PACKAGE_GLOB" -print -quit 2>/dev/null | grep -q .; then
    cat >&2 <<EOF
BOOT_KERNEL_SOURCE=camera-package requires a staged aarch64 kernel package.

Expected in $LOCAL_PACKAGE_DIR:
  $CAMERA_KERNEL_PACKAGE_GLOB
EOF
    exit 1
  fi
}

require_sensor_local_packages() {
  if [[ "${ENABLE_HEXAGON_SENSORS:-1}" != "1" ]]; then
    return
  fi

  if ! find "$LOCAL_PACKAGE_DIR" -maxdepth 1 \( -type f -o -type l \) \
    -name 'hexagonrpcd-*-aarch64.pkg.tar.*' -print -quit 2>/dev/null | grep -q .; then
    cat >&2 <<EOF
ENABLE_HEXAGON_SENSORS=1 requires a staged hexagonrpcd aarch64 package.

Build and stage it before building the root image:
  scripts/build-hexagonrpcd-package.sh oneplus-fajita

Expected staged package:
  $LOCAL_PACKAGE_DIR/hexagonrpcd-*-aarch64.pkg.tar.*

For a recovery image without sensors, build with:
  ENABLE_HEXAGON_SENSORS=0 scripts/build-rootfs-image.sh oneplus-fajita
EOF
    exit 1
  fi
}

write_alarm_pacman_conf() {
  mkdir -p "$PACMAN_CACHE_DIR" "$PACMAN_HOOK_DIR"
  cat > "$PACMAN_CONF" <<'EOF'
[options]
Architecture = aarch64
SigLevel = Never
LocalFileSigLevel = Never
ParallelDownloads = 5
DisableSandbox

[core]
Server = http://mirror.archlinuxarm.org/$arch/$repo

[extra]
Server = http://mirror.archlinuxarm.org/$arch/$repo

[alarm]
Server = http://mirror.archlinuxarm.org/$arch/$repo

[aur]
Server = http://mirror.archlinuxarm.org/$arch/$repo
EOF
}

disable_target_pacman_hooks() {
  mkdir -p "$MNT_DIR/etc/pacman.d/hooks"

  # This image boots the PMOS initramfs copied into /boot. The stock Arch
  # mkinitcpio hooks expect /proc in a live chroot and only produce noisy
  # failures during offline image assembly.
  ln -sfn /dev/null "$MNT_DIR/etc/pacman.d/hooks/60-mkinitcpio-remove.hook"
  ln -sfn /dev/null "$MNT_DIR/etc/pacman.d/hooks/90-mkinitcpio-install.hook"
}

install_profile_packages() {
  if [[ "$INSTALL_PROFILE_PACKAGES" != "1" ]]; then
    echo "Skipping profile package installation because INSTALL_PROFILE_PACKAGES=$INSTALL_PROFILE_PACKAGES"
    return
  fi

  read_package_manifest
  if [[ "${#PROFILE_PACKAGES[@]}" -eq 0 ]]; then
    echo "Package manifest is empty: $PACKAGE_MANIFEST"
    return
  fi

  write_alarm_pacman_conf
  echo "Installing ${#PROFILE_PACKAGES[@]} profile packages into root image:"
  printf '  %s\n' "${PROFILE_PACKAGES[@]}"

  pacman \
    --root "$MNT_DIR" \
    --config "$PACMAN_CONF" \
    --cachedir "$PACMAN_CACHE_DIR" \
    --logfile "$PACMAN_LOG" \
    --hookdir "$PACMAN_HOOK_DIR" \
    --arch aarch64 \
    --noconfirm \
    --needed \
    --noscriptlet \
    -Sy "${PROFILE_PACKAGES[@]}"
}

remove_conflicting_stock_kernel() {
  if [[ "${BOOT_KERNEL_SOURCE:-pmos-snapshot}" != "camera-package" ]]; then
    return
  fi

  write_alarm_pacman_conf
  if ! pacman --root "$MNT_DIR" --config "$PACMAN_CONF" --arch aarch64 \
    -Q linux-aarch64 >/dev/null 2>&1; then
    return
  fi

  echo "Removing generic linux-aarch64 before installing the OnePlus camera kernel."
  pacman \
    --root "$MNT_DIR" \
    --config "$PACMAN_CONF" \
    --logfile "$PACMAN_LOG" \
    --hookdir "$PACMAN_HOOK_DIR" \
    --arch aarch64 \
    --noconfirm \
    -Rdd linux-aarch64
}

install_local_packages() {
  local packages=()
  local package
  local package_info
  local package_name
  local package_version
  local old_version
  local existing
  local -a package_names=()
  local -A selected_package=()
  local -A selected_version=()

  should_install_local_package() {
    local name="$1"

    case "$name" in
      linux-oneplus6t-camera)
        if [[ "${BOOT_KERNEL_SOURCE:-pmos-snapshot}" != "camera-package" ]]; then
          echo "Skipping local camera kernel package for PMOS-snapshot golden image: $name"
          echo "  Set BOOT_KERNEL_SOURCE=camera-package to include it."
          return 1
        fi
        ;;
    esac

    return 0
  }

  if [[ ! -d "$LOCAL_PACKAGE_DIR" ]]; then
    echo "No local package directory found; skipping local package injection."
    echo "  $LOCAL_PACKAGE_DIR"
    return
  fi

  while IFS= read -r -d '' package; do
    package_info="$(pacman -Qp "$package")"
    package_name="${package_info%% *}"
    package_version="${package_info#* }"

    if ! should_install_local_package "$package_name"; then
      echo "  skipped: $package"
      continue
    fi

    if [[ -z "${selected_package[$package_name]:-}" ]]; then
      package_names+=("$package_name")
      selected_package["$package_name"]="$package"
      selected_version["$package_name"]="$package_version"
      continue
    fi

    existing="${selected_package[$package_name]}"
    old_version="${selected_version[$package_name]}"
    if (( $(vercmp "$package_version" "$old_version") > 0 )); then
      echo "Selecting newer local package for $package_name: $package_version"
      echo "  replacing: $existing"
      echo "  with:      $package"
      selected_package["$package_name"]="$package"
      selected_version["$package_name"]="$package_version"
    else
      echo "Skipping older duplicate local package for $package_name: $package_version"
      echo "  keeping: $existing"
      echo "  skipped: $package"
    fi
  done < <(find "$LOCAL_PACKAGE_DIR" -maxdepth 1 \( -type f -o -type l \) \
    \( -name '*.pkg.tar.zst' -o -name '*.pkg.tar.xz' -o -name '*.pkg.tar.gz' -o -name '*.pkg.tar' \) \
    -print0 | sort -z)

  for package_name in "${package_names[@]}"; do
    packages+=("${selected_package[$package_name]}")
  done

  if [[ "${#packages[@]}" -eq 0 ]]; then
    echo "No local packages found; skipping local package injection."
    echo "  $LOCAL_PACKAGE_DIR"
    return
  fi

  write_alarm_pacman_conf
  echo "Installing ${#packages[@]} local package(s) into root image:"
  printf '  %s\n' "${packages[@]}"

  pacman \
    --root "$MNT_DIR" \
    --config "$PACMAN_CONF" \
    --cachedir "$PACMAN_CACHE_DIR" \
    --logfile "$PACMAN_LOG" \
    --hookdir "$PACMAN_HOOK_DIR" \
    --arch aarch64 \
    --noconfirm \
    --needed \
    --noscriptlet \
    -U "${packages[@]}"
}

write_pacman_runtime_config() {
  local conf="$MNT_DIR/etc/pacman.conf"

  if [[ ! -f "$conf" ]]; then
    return
  fi

  if ! grep -Eq '^[[:space:]]*DisableSandbox([[:space:]]|$)' "$conf"; then
    sed -i '/^\[options\]/a DisableSandbox' "$conf"
  fi
}

main() {
  need_root
  require_tools
  validate_pmos_boot_files
  require_sensor_local_packages
  require_camera_kernel_package
  download_rootfs

  rm -rf "$WORK_DIR"
  mkdir -p "$OUT_DIR" "$WORK_DIR" "$MNT_DIR"
  trap cleanup_mount EXIT

  rm -f "$RAW_IMG" "$SPARSE_IMG" "$RAW_IMG.sha256" "$SPARSE_IMG.sha256"
  truncate -s "$ROOT_IMAGE_SIZE" "$RAW_IMG"
  local mkfs_args=(-f -L "$ROOT_LABEL" -U "$ROOT_UUID")
  if [[ -n "$BTRFS_MKFS_FEATURES" ]]; then
    mkfs_args+=(-O "$BTRFS_MKFS_FEATURES")
  fi
  mkfs.btrfs "${mkfs_args[@]}" "$RAW_IMG"
  mount -o loop,rw,noatime,compress=zstd:3 "$RAW_IMG" "$MNT_DIR"

  tar -xpf "$ROOTFS_TARBALL" -C "$MNT_DIR"
  disable_target_pacman_hooks
  install_profile_packages
  remove_conflicting_stock_kernel
  install_local_packages
  write_pacman_runtime_config
  install_pmos_boot_files

  cat > "$MNT_DIR/etc/fstab" <<EOF
# linuxphone Arch root on ${ROOT_DEVICE}
UUID=${ROOT_UUID} / btrfs rw,noatime,compress=zstd:3 0 1
EOF

  enable_sshd_service

  apply_overlay
  configure_installer_identity
  write_installer_wifi_config
  write_installer_mobile_apn_config
  write_installer_app_launcher_config
  install_source_cache wvkbd "$WVKBD_SOURCE_CACHE_DIR" "$WVKBD_REF"
  install_source_cache hyperrotation "$HYPERROTATION_SOURCE_CACHE_DIR" "$HYPERROTATION_REF"
  install_ssh_onboarding
  install_pmos_hardware_reference
  install_pmos_compat_payload
  ensure_hyprland_profile_includes
  fix_profile_ownership
  fix_privileged_helper_modes
  enable_insecure_password_if_requested

  sync
  umount "$MNT_DIR"
  trap - EXIT

  if command -v img2simg >/dev/null 2>&1; then
    img2simg "$RAW_IMG" "$SPARSE_IMG"
    sha256sum "$SPARSE_IMG" > "$SPARSE_IMG.sha256"
    echo "Built Android sparse root image:"
    echo "$SPARSE_IMG"
    cat "$SPARSE_IMG.sha256"
  else
    sha256sum "$RAW_IMG" > "$RAW_IMG.sha256"
    echo "img2simg not found; built raw root image only:"
    echo "$RAW_IMG"
    cat "$RAW_IMG.sha256"
  fi
}

main "$@"
