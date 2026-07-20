#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<EOF
Usage: CONFIRM_FLASH=1 $0 [profile]

Flashes the paired release artifacts:
  fastboot flash boot     out/<profile>/oneplus6t-arch-boot.img
  fastboot flash userdata out/<profile>/oneplus6t-arch-root.img

This replaces userdata. By default the script flashes the real Btrfs root image
once without a preceding fastboot erase. The userdata preflight warns if the
root image virtual size is smaller than the live userdata partition.
Set REBOOT_AFTER_FLASH=0 to skip fastboot reboot.
Set USERDATA_PREFLIGHT=strict to refuse undersized root images.
Set FASTBOOT_REBOOT_MODE=direct only for lab debugging host-side reboot hangs.
Set FASTBOOT_REBOOT_FALLBACK=none to skip the second reboot fallback.
Set FASTBOOT_SPARSE_SIZE=16M to match the known-good PMOS-style transfer shape.
Set DISABLE_ANDROID_VERIFICATION=0 only if you intentionally keep stock vbmeta.
Set FASTBOOT_FLASH_TIMEOUT_SECONDS=900 to change flash command timeout.
EOF
  exit 0
fi

PROFILE="${1:-oneplus-fajita}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/out/$PROFILE}"
BOOT_IMG="$OUT_DIR/oneplus6t-arch-boot.img"
ROOT_IMG="$OUT_DIR/oneplus6t-arch-root.img"
BOOT_SUM="$BOOT_IMG.sha256"
ROOT_SUM="$ROOT_IMG.sha256"
REBOOT_AFTER_FLASH="${REBOOT_AFTER_FLASH:-1}"
FASTBOOT_REBOOT_MODE="${FASTBOOT_REBOOT_MODE:-timeout}"
FASTBOOT_REBOOT_FALLBACK="${FASTBOOT_REBOOT_FALLBACK:-reboot}"
FASTBOOT_REBOOT_AS_CALLER="${FASTBOOT_REBOOT_AS_CALLER:-1}"
FASTBOOT_REBOOT_SETTLE_SECONDS="${FASTBOOT_REBOOT_SETTLE_SECONDS:-10}"
FASTBOOT_REBOOT_COMMAND_TIMEOUT_SECONDS="${FASTBOOT_REBOOT_COMMAND_TIMEOUT_SECONDS:-20}"
FASTBOOT_PROBE_TIMEOUT_SECONDS="${FASTBOOT_PROBE_TIMEOUT_SECONDS:-3}"
FASTBOOT_READY_WAIT_SECONDS="${FASTBOOT_READY_WAIT_SECONDS:-120}"
FASTBOOT_READY_RETRY_SECONDS="${FASTBOOT_READY_RETRY_SECONDS:-2}"
FASTBOOT_COMMAND_ATTEMPTS="${FASTBOOT_COMMAND_ATTEMPTS:-3}"
FASTBOOT_FLASH_TIMEOUT_SECONDS="${FASTBOOT_FLASH_TIMEOUT_SECONDS:-900}"
FASTBOOT_BOOT_FLASH_TIMEOUT_SECONDS="${FASTBOOT_BOOT_FLASH_TIMEOUT_SECONDS:-120}"
FASTBOOT_ERASE_TIMEOUT_SECONDS="${FASTBOOT_ERASE_TIMEOUT_SECONDS:-120}"
ALLOW_FASTBOOT_USERDATA_SIZE_FALLBACK="${ALLOW_FASTBOOT_USERDATA_SIZE_FALLBACK:-0}"
ERASE_USERDATA_BEFORE_FLASH="${ERASE_USERDATA_BEFORE_FLASH:-0}"
EXT4_CLEANSTAGE_BEFORE_BTRFS="${EXT4_CLEANSTAGE_BEFORE_BTRFS:-0}"
EXT4_CLEANSTAGE_SIZE="${EXT4_CLEANSTAGE_SIZE:-}"
EXT4_CLEANSTAGE_RAW="${EXT4_CLEANSTAGE_RAW:-$OUT_DIR/oneplus6t-cleanstage-ext4.raw.img}"
EXT4_CLEANSTAGE_IMG="${EXT4_CLEANSTAGE_IMG:-$OUT_DIR/oneplus6t-cleanstage-ext4.img}"
ROOT_FLASH_PASSES="${ROOT_FLASH_PASSES:-1}"
FASTBOOT_SPARSE_SIZE="${FASTBOOT_SPARSE_SIZE:-16M}"
USERDATA_PREFLIGHT="${USERDATA_PREFLIGHT:-warn}"
DISABLE_ANDROID_VERIFICATION="${DISABLE_ANDROID_VERIFICATION:-1}"
VBMETA_DISABLED_IMG="${VBMETA_DISABLED_IMG:-$OUT_DIR/oneplus6t-vbmeta-disabled.img}"

usage() {
  cat <<EOF
Usage: CONFIRM_FLASH=1 $0 [profile]

Flashes the paired release artifacts:
  fastboot flash boot     $BOOT_IMG
  fastboot flash userdata $ROOT_IMG

This replaces userdata. Set ERASE_USERDATA_BEFORE_FLASH=1 only for low-level
debugging when you intentionally want to clear Android userdata metadata before
the root image write.

Optional EXT4_CLEANSTAGE_BEFORE_BTRFS=1 creates and flashes:
  $EXT4_CLEANSTAGE_IMG

That clean-stage image formats userdata as ext4 before the real Btrfs sparse
image is flashed once. It is disabled by default because direct Btrfs flashing
is disabled by default because it has hung during OnePlus 6T fastboot tests.
ROOT_FLASH_PASSES defaults to 1.
Set REBOOT_AFTER_FLASH=0 to skip fastboot reboot.
Set USERDATA_PREFLIGHT=warn to print userdata/root-size risk and continue.
Set USERDATA_PREFLIGHT=strict to refuse undersized root images.
Set USERDATA_PREFLIGHT=off to skip the userdata/root-size check.
Set FASTBOOT_REBOOT_MODE=timeout to wrap fastboot reboot with timeout.
Set FASTBOOT_REBOOT_MODE=direct to use plain fastboot reboot.
Set FASTBOOT_REBOOT_FALLBACK=reboot to try one more bounded fastboot reboot if the phone stays in fastboot.
Set FASTBOOT_REBOOT_AS_CALLER=1 to run reboot commands as the original sudo/doas user when possible.
Set FASTBOOT_SPARSE_SIZE=0 to let fastboot choose its default sparse transfer size.
Set DISABLE_ANDROID_VERIFICATION=1 to flash disabled vbmeta for the active slot before boot.
Set FASTBOOT_FLASH_TIMEOUT_SECONDS to bound long userdata flash hangs.
EOF
}

require_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "Missing required artifact: $path" >&2
    exit 1
  fi
}

for tool in fastboot sha256sum timeout; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool: $tool" >&2
    exit 1
  fi
done

if [[ "$DISABLE_ANDROID_VERIFICATION" == "1" ]] && ! command -v avbtool >/dev/null 2>&1; then
  echo "Missing required tool for DISABLE_ANDROID_VERIFICATION=1: avbtool" >&2
  exit 1
fi

if [[ "$USERDATA_PREFLIGHT" != "off" ]] && ! command -v python3 >/dev/null 2>&1; then
  echo "Missing required tool for USERDATA_PREFLIGHT=$USERDATA_PREFLIGHT: python3" >&2
  exit 1
fi

if [[ "$EXT4_CLEANSTAGE_BEFORE_BTRFS" == "1" ]]; then
  for tool in mkfs.ext4 img2simg truncate stat; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "Missing required tool for ext4 clean-stage image: $tool" >&2
      exit 1
    fi
  done
fi

require_file "$BOOT_IMG"
require_file "$ROOT_IMG"
require_file "$BOOT_SUM"
require_file "$ROOT_SUM"

if [[ ! "$ROOT_FLASH_PASSES" =~ ^[1-9][0-9]*$ ]]; then
  echo "ROOT_FLASH_PASSES must be a positive integer, got: $ROOT_FLASH_PASSES" >&2
  exit 1
fi

if [[ ! "$FASTBOOT_COMMAND_ATTEMPTS" =~ ^[1-9][0-9]*$ ]]; then
  echo "FASTBOOT_COMMAND_ATTEMPTS must be a positive integer, got: $FASTBOOT_COMMAND_ATTEMPTS" >&2
  exit 1
fi

build_ext4_cleanstage_image() {
  local raw_size

  if [[ -n "$EXT4_CLEANSTAGE_SIZE" ]]; then
    raw_size="$EXT4_CLEANSTAGE_SIZE"
  elif [[ -f "$OUT_DIR/oneplus6t-arch-root.raw.img" ]]; then
    raw_size="$(stat -c %s "$OUT_DIR/oneplus6t-arch-root.raw.img")"
  else
    raw_size="8G"
  fi

  echo "Building throwaway ext4 clean-stage userdata image."
  echo "  raw:    $EXT4_CLEANSTAGE_RAW"
  echo "  sparse: $EXT4_CLEANSTAGE_IMG"
  echo "  size:   $raw_size"

  rm -f "$EXT4_CLEANSTAGE_RAW" "$EXT4_CLEANSTAGE_IMG"
  truncate -s "$raw_size" "$EXT4_CLEANSTAGE_RAW"
  mkfs.ext4 -F -L cleanstage "$EXT4_CLEANSTAGE_RAW"
  img2simg "$EXT4_CLEANSTAGE_RAW" "$EXT4_CLEANSTAGE_IMG"
  rm -f "$EXT4_CLEANSTAGE_RAW"
}

run_userdata_preflight() {
  case "$USERDATA_PREFLIGHT" in
    off)
      echo "Skipping userdata preflight because USERDATA_PREFLIGHT=off"
      ;;
    warn|strict)
      USERDATA_PREFLIGHT="$USERDATA_PREFLIGHT" \
        ROOT_IMG="$ROOT_IMG" \
        OUT_DIR="$OUT_DIR" \
        "$ROOT_DIR/scripts/fastboot-userdata-preflight.sh" "$PROFILE"
      ;;
    *)
      echo "Invalid USERDATA_PREFLIGHT=$USERDATA_PREFLIGHT; expected warn, strict, or off." >&2
      exit 1
      ;;
  esac
}

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
wedged. If the phone is not in fastboot, put it back into fastboot now and
leave it connected.
EOF
    fi

    sleep "$FASTBOOT_READY_RETRY_SECONDS"
    elapsed=$((elapsed + FASTBOOT_READY_RETRY_SECONDS))
  done

  echo "Fastboot did not become command-ready within ${FASTBOOT_READY_WAIT_SECONDS}s." >&2
  echo "Current fastboot device list:" >&2
  fastboot devices -l >&2 || true
  print_flash_resume_hint
  exit 1
}

fastboot_getvar_value() {
  local key="$1"
  local output
  local value

  output="$(timeout "${FASTBOOT_PROBE_TIMEOUT_SECONDS}s" fastboot getvar "$key" 2>&1 || true)"
  value="$(awk -v key="$key" '
    {
      line = $0
      sub(/^\(bootloader\) /, "", line)
      prefix = key ":"
      if (index(line, prefix) == 1) {
        value = substr(line, length(prefix) + 1)
        sub(/^[[:space:]]+/, "", value)
        sub(/[[:space:]]+$/, "", value)
        print value
        exit
      }
    }
  ' <<<"$output")"
  value="${value//$'\r'/}"
  printf '%s\n' "$value"
}

print_flash_resume_hint() {
  cat >&2 <<EOF

Resume without rebuilding:
  CONFIRM_FLASH=1 USERDATA_PREFLIGHT=$USERDATA_PREFLIGHT FASTBOOT_SPARSE_SIZE=$FASTBOOT_SPARSE_SIZE DISABLE_ANDROID_VERIFICATION=$DISABLE_ANDROID_VERIFICATION "$ROOT_DIR/scripts/flash-release.sh" "$PROFILE"

This reuses the already-built images:
  $BOOT_IMG
  $ROOT_IMG
EOF
}

flash_disabled_vbmeta_for_active_slot() {
  local slot
  local vbmeta_partition
  local vbmeta_size_hex
  local vbmeta_size

  if [[ "$DISABLE_ANDROID_VERIFICATION" != "1" ]]; then
    echo "Skipping disabled vbmeta flash because DISABLE_ANDROID_VERIFICATION=$DISABLE_ANDROID_VERIFICATION"
    return 0
  fi

  slot="$(fastboot_getvar_value current-slot)"
  slot="${slot:-a}"
  slot="${slot#_}"
  if [[ ! "$slot" =~ ^[ab]$ ]]; then
    echo "WARN: unexpected current-slot value from fastboot: ${slot:-empty}; defaulting to slot a for vbmeta." >&2
    slot="a"
  fi
  vbmeta_partition="vbmeta_${slot}"
  vbmeta_size_hex="$(fastboot_getvar_value "partition-size:${vbmeta_partition}")"
  if [[ ! "$vbmeta_size_hex" =~ ^0x[0-9A-Fa-f]+$ ]]; then
    echo "WARN: could not read a valid size for $vbmeta_partition from fastboot: ${vbmeta_size_hex:-empty}" >&2
    echo "WARN: using known OnePlus 6T vbmeta fallback size 0x10000." >&2
    vbmeta_size_hex="0x10000"
  fi
  vbmeta_size="$((16#${vbmeta_size_hex#0x}))"

  echo "Building disabled vbmeta image for active slot $slot."
  echo "  partition: $vbmeta_partition"
  echo "  size:      $vbmeta_size bytes ($vbmeta_size_hex)"
  avbtool make_vbmeta_image --flags 2 --padding_size "$vbmeta_size" --output "$VBMETA_DISABLED_IMG"
  run_fastboot_bounded "$FASTBOOT_BOOT_FLASH_TIMEOUT_SECONDS" fastboot flash "$vbmeta_partition" "$VBMETA_DISABLED_IMG"
}

sha256sum -c "$BOOT_SUM"
sha256sum -c "$ROOT_SUM"

wait_for_fastboot_ready "before userdata preflight"

run_userdata_preflight

if [[ "$USERDATA_PREFLIGHT" == "off" ]]; then
  wait_for_fastboot_ready "before flash"
fi

if [[ "${CONFIRM_FLASH:-0}" != "1" ]]; then
  usage >&2
  echo >&2
  echo "Refusing to flash without CONFIRM_FLASH=1." >&2
  exit 1
fi

echo "Flashing paired OnePlus 6T Arch release artifacts:"
echo "  boot:     $BOOT_IMG"
echo "  userdata: $ROOT_IMG"
echo "  sparse transfer size: $FASTBOOT_SPARSE_SIZE"
echo "  userdata flash timeout: ${FASTBOOT_FLASH_TIMEOUT_SECONDS}s"

run_fastboot_bounded() {
  local timeout_seconds="$1"
  local attempt
  local status
  shift

  for ((attempt = 1; attempt <= FASTBOOT_COMMAND_ATTEMPTS; attempt++)); do
    echo "Running with ${timeout_seconds}s timeout, attempt ${attempt}/${FASTBOOT_COMMAND_ATTEMPTS}: $*"
    if timeout -k 5s "${timeout_seconds}s" "$@"; then
      return 0
    fi

    status=$?
    cat >&2 <<EOF
Fastboot command failed or timed out after ${timeout_seconds}s:
  $*

EOF

    print_flash_resume_hint

    if (( attempt < FASTBOOT_COMMAND_ATTEMPTS )); then
      echo "Retrying automatically. Press Ctrl+C now if you want to stop." >&2
      wait_for_fastboot_ready "after failed fastboot command, before retry ${attempt}/${FASTBOOT_COMMAND_ATTEMPTS}"
    else
      cat >&2 <<EOF
Fastboot command failed after ${FASTBOOT_COMMAND_ATTEMPTS} attempt(s).
If the phone is still in fastboot, leave it there and rerun the resume command above.
EOF
      return "$status"
    fi
  done
}

fastboot_flash_userdata() {
  local image="$1"
  if [[ "$FASTBOOT_SPARSE_SIZE" == "0" || -z "$FASTBOOT_SPARSE_SIZE" ]]; then
    run_fastboot_bounded "$FASTBOOT_FLASH_TIMEOUT_SECONDS" fastboot flash userdata "$image"
  else
    run_fastboot_bounded "$FASTBOOT_FLASH_TIMEOUT_SECONDS" fastboot -S "$FASTBOOT_SPARSE_SIZE" flash userdata "$image"
  fi
}

fastboot_action_cmd=()

set_fastboot_action_cmd() {
  local action="$1"
  local caller="${SUDO_USER:-${DOAS_USER:-}}"

  fastboot_action_cmd=(fastboot "$action")
  if [[ "$FASTBOOT_REBOOT_AS_CALLER" == "1" && "${EUID:-$(id -u)}" -eq 0 && \
        -n "$caller" && "$caller" != "root" && "$caller" != "0" && \
        "$(command -v runuser || true)" ]]; then
    fastboot_action_cmd=(runuser -u "$caller" -- fastboot "$action")
  fi
}

run_fastboot_reboot_action() {
  local action="$1"
  local mode="${2:-$FASTBOOT_REBOOT_MODE}"

  set_fastboot_action_cmd "$action"
  echo "Running: ${fastboot_action_cmd[*]}"
  case "$mode" in
    direct)
      "${fastboot_action_cmd[@]}"
      ;;
    timeout)
      echo "Running fastboot $action with a ${FASTBOOT_REBOOT_COMMAND_TIMEOUT_SECONDS}s timeout."
      timeout "${FASTBOOT_REBOOT_COMMAND_TIMEOUT_SECONDS}s" "${fastboot_action_cmd[@]}"
      ;;
    *)
      echo "Invalid FASTBOOT_REBOOT_MODE=$mode; expected direct or timeout." >&2
      exit 1
      ;;
  esac
}

if [[ "$EXT4_CLEANSTAGE_BEFORE_BTRFS" == "1" ]]; then
  build_ext4_cleanstage_image
fi

flash_disabled_vbmeta_for_active_slot
run_fastboot_bounded "$FASTBOOT_BOOT_FLASH_TIMEOUT_SECONDS" fastboot flash boot "$BOOT_IMG"
if [[ "$ERASE_USERDATA_BEFORE_FLASH" == "1" ]]; then
  echo "Erasing userdata before sparse root flash."
  echo "This clears the Android userdata partition before the clean-stage/root writes."
  run_fastboot_bounded "$FASTBOOT_ERASE_TIMEOUT_SECONDS" fastboot erase userdata
else
  echo "Skipping userdata erase because ERASE_USERDATA_BEFORE_FLASH=$ERASE_USERDATA_BEFORE_FLASH"
  echo "This preserves the older known-good direct boot + userdata flash shape."
fi
if [[ "$EXT4_CLEANSTAGE_BEFORE_BTRFS" == "1" ]]; then
  echo "Flashing throwaway ext4 clean-stage userdata image."
  echo "This intentionally changes userdata filesystem metadata before the real Btrfs root flash."
  fastboot_flash_userdata "$EXT4_CLEANSTAGE_IMG"
else
  echo "Skipping ext4 clean-stage because EXT4_CLEANSTAGE_BEFORE_BTRFS=$EXT4_CLEANSTAGE_BEFORE_BTRFS"
fi
for ((pass = 1; pass <= ROOT_FLASH_PASSES; pass++)); do
  echo "Flashing userdata sparse image: pass $pass/$ROOT_FLASH_PASSES"
  fastboot_flash_userdata "$ROOT_IMG"
done

if [[ "$REBOOT_AFTER_FLASH" == "1" ]]; then
  echo "Rebooting phone with fastboot."
  echo "If the phone does not leave fastboot automatically, manually start it from the fastboot menu."
  reboot_completed=1
  if ! run_fastboot_reboot_action reboot; then
    reboot_completed=0
  fi
  if [[ "$reboot_completed" != "1" ]]; then
    cat >&2 <<'EOF'
fastboot reboot did not return cleanly.
The flash is complete. If the phone is still in fastboot, manually start it from the fastboot menu now.
EOF
  fi
  if [[ "$reboot_completed" == "1" ]]; then
    echo "fastboot reboot sent."
  else
    echo "Continuing with fastboot settle check after reboot command timeout."
  fi
  echo "Waiting ${FASTBOOT_REBOOT_SETTLE_SECONDS}s to see whether the phone leaves fastboot."
  sleep "$FASTBOOT_REBOOT_SETTLE_SECONDS"
  if timeout "${FASTBOOT_PROBE_TIMEOUT_SECONDS}s" fastboot devices -l 2>&1 | awk 'NF >= 2 && $2 == "fastboot" { found = 1 } END { exit !found }'; then
    case "$FASTBOOT_REBOOT_FALLBACK" in
      reboot)
        echo "Phone still appears in fastboot; trying one more fastboot reboot."
        if ! run_fastboot_reboot_action reboot timeout; then
          echo "second fastboot reboot did not return cleanly."
        fi
        echo "Waiting ${FASTBOOT_REBOOT_SETTLE_SECONDS}s after second fastboot reboot."
        sleep "$FASTBOOT_REBOOT_SETTLE_SECONDS"
        ;;
      continue)
        echo "Phone still appears in fastboot; trying optional fastboot continue fallback."
        if ! run_fastboot_reboot_action continue timeout; then
          echo "fastboot continue did not return cleanly or is not supported by this fastboot build."
        fi
        echo "Waiting ${FASTBOOT_REBOOT_SETTLE_SECONDS}s after fastboot continue."
        sleep "$FASTBOOT_REBOOT_SETTLE_SECONDS"
        ;;
      none)
        ;;
      *)
        echo "Invalid FASTBOOT_REBOOT_FALLBACK=$FASTBOOT_REBOOT_FALLBACK; expected reboot, continue, or none." >&2
        exit 1
        ;;
    esac
    if timeout "${FASTBOOT_PROBE_TIMEOUT_SECONDS}s" fastboot devices -l 2>&1 | awk 'NF >= 2 && $2 == "fastboot" { found = 1 } END { exit !found }'; then
      echo "Phone still appears in fastboot. Manually start it from the fastboot menu now."
      exit 1
    else
      echo "Phone no longer appears in fastboot after fallback; boot likely started."
    fi
  else
    echo "Phone no longer appears in fastboot; boot likely started."
  fi
else
  echo "Skipping reboot because REBOOT_AFTER_FLASH=$REBOOT_AFTER_FLASH"
fi
