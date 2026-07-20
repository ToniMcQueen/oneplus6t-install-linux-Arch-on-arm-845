#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${1:-oneplus-fajita}"
PROFILE_DIR="$ROOT_DIR/profiles/$PROFILE"
if [[ -f "$PROFILE_DIR/config.env" ]]; then
  # shellcheck source=/dev/null
  source "$PROFILE_DIR/config.env"
fi
OUT_DIR="${OUT_DIR:-$ROOT_DIR/out/$PROFILE}"
ROOT_IMG="${ROOT_IMG:-$OUT_DIR/oneplus6t-arch-root.img}"
MODE="${USERDATA_PREFLIGHT:-warn}"
FASTBOOT_PROBE_TIMEOUT_SECONDS="${FASTBOOT_PROBE_TIMEOUT_SECONDS:-3}"
ALLOW_FASTBOOT_USERDATA_SIZE_FALLBACK="${ALLOW_FASTBOOT_USERDATA_SIZE_FALLBACK:-0}"

usage() {
  cat <<EOF
Usage: USERDATA_PREFLIGHT=warn|strict|off $0 [profile]

Checks the generated userdata image against the live fastboot userdata
partition. This does not flash or modify the phone.

warn   print a stale-tail risk warning but exit 0
strict exit non-zero when the root image virtual size is smaller than userdata
off    skip the check
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "$MODE" == "off" ]]; then
  echo "userdata preflight skipped because USERDATA_PREFLIGHT=off"
  exit 0
fi

if [[ "$MODE" != "warn" && "$MODE" != "strict" ]]; then
  echo "Invalid USERDATA_PREFLIGHT=$MODE; expected warn, strict, or off." >&2
  exit 1
fi

for tool in fastboot python3 timeout; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool: $tool" >&2
    exit 1
  fi
done

if [[ ! -f "$ROOT_IMG" ]]; then
  echo "Missing root image: $ROOT_IMG" >&2
  exit 1
fi

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

userdata_hex="$(fastboot_getvar_value partition-size:userdata)"
case "$userdata_hex" in
  0x*|0X*) ;;
  *)
    echo "Unexpected userdata size from fastboot: $userdata_hex" >&2
    exit 1
    ;;
esac

userdata_bytes=$((userdata_hex))
root_virtual_bytes="$(python3 "$ROOT_DIR/scripts/android-sparse-info.py" --field virtual_size_bytes "$ROOT_IMG")"
root_format="$(python3 "$ROOT_DIR/scripts/android-sparse-info.py" --field format "$ROOT_IMG")"

if (( userdata_bytes <= 0 )); then
  echo "Invalid userdata partition size: $userdata_bytes" >&2
  exit 1
fi

if (( root_virtual_bytes <= 0 )); then
  echo "Invalid root image virtual size: $root_virtual_bytes" >&2
  exit 1
fi

echo "== userdata preflight =="
echo "fastboot userdata size: $userdata_bytes bytes ($userdata_hex)"
echo "root image format:      $root_format"
echo "root image virtual:     $root_virtual_bytes bytes"

if (( root_virtual_bytes > userdata_bytes )); then
  echo "USERDATA_PREFLIGHT_STATUS=too-large"
  echo "Root image is larger than userdata; refusing to flash." >&2
  exit 1
fi

if (( root_virtual_bytes < userdata_bytes )); then
  tail_bytes=$((userdata_bytes - root_virtual_bytes))
  echo "USERDATA_PREFLIGHT_STATUS=tail-risk"
  echo "unwritten userdata tail: $tail_bytes bytes"
  cat >&2 <<EOF
The root image is smaller than the userdata partition.
On repeated OnePlus 6T fastboot flashes, that can leave old filesystem state in
the tail that the first boot later grows into.

Preferred fix for a from-start install:
  build with ROOT_IMAGE_SIZE_FROM_FASTBOOT=1, then flash again.
EOF
  if [[ "$MODE" == "strict" ]]; then
    exit 2
  fi
  exit 0
fi

echo "USERDATA_PREFLIGHT_STATUS=matched"
echo "OK: root image virtual size matches userdata; normal flash path is allowed."
