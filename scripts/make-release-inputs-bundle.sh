#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="oneplus-fajita"
ASSET_NAME="${RELEASE_INPUTS_ASSET:-oneplus6t-release-inputs.tar.zst}"
INCLUDE_CAMERA_PACKAGES="${INCLUDE_CAMERA_PACKAGES:-1}"

usage() {
  cat <<'EOF'
Usage: scripts/make-release-inputs-bundle.sh [options]

Build the release input bundle consumed by scripts/fetch-release-inputs.sh.
This is for maintainers publishing GitHub Release assets, not for normal users.

Options:
  --profile NAME       Device profile, default: oneplus-fajita
  --asset NAME         Output asset name, default: oneplus6t-release-inputs.tar.zst
  --include-camera     Include staged linux-oneplus6t-camera research packages
  --exclude-camera     Exclude staged linux-oneplus6t-camera research packages
  -h, --help          Show this help

The bundle contains the non-git inputs needed for clone-and-go public installs:
  vendor/pmos-oneplus-fajita/boot/
  out/oneplus-fajita/packages/
  vendor/pmos-compat-payload/                    when present
  vendor/pmos-reference/*.tar.zst                when present
EOF
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --profile)
      PROFILE="${2:?missing value for --profile}"
      shift 2
      ;;
    --asset)
      ASSET_NAME="${2:?missing value for --asset}"
      shift 2
      ;;
    --include-camera)
      INCLUDE_CAMERA_PACKAGES=1
      shift
      ;;
    --exclude-camera)
      INCLUDE_CAMERA_PACKAGES=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

PROFILE_DIR="$ROOT_DIR/profiles/$PROFILE"
if [[ ! -f "$PROFILE_DIR/config.env" ]]; then
  echo "Unknown profile or missing config: $PROFILE_DIR/config.env" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$PROFILE_DIR/config.env"

OUT_DIR="${OUT_DIR:-$ROOT_DIR/out/$PROFILE}"
LOCAL_PACKAGE_DIR="${LOCAL_PACKAGE_DIR:-$OUT_DIR/packages}"
PMOS_BOOT_DIR="${PMOS_BOOT_DIR:-$ROOT_DIR/vendor/pmos-oneplus-fajita/boot}"
PMOS_COMPAT_PAYLOAD_DIR="${PMOS_COMPAT_PAYLOAD_DIR:-$ROOT_DIR/vendor/pmos-compat-payload}"
PMOS_HARDWARE_REFERENCE_TARBALL="${PMOS_HARDWARE_REFERENCE_TARBALL:-$ROOT_DIR/vendor/pmos-reference/pmos-v24.06-oneplus-fajita-hardware-reference.tar.zst}"
RELEASE_INPUTS_DIR="${RELEASE_INPUTS_DIR:-$OUT_DIR/release-inputs}"
RELEASE_INPUTS_TMP=""

cleanup() {
  if [[ -n "$RELEASE_INPUTS_TMP" ]]; then
    rm -rf "$RELEASE_INPUTS_TMP"
  fi
}

required_boot_files=(
  "$PMOS_BOOT_DIR/$PMOS_KERNEL"
  "$PMOS_BOOT_DIR/$PMOS_INITRAMFS"
  "$PMOS_BOOT_DIR/$PMOS_INITRAMFS_EXTRA"
  "$PMOS_BOOT_DIR/$PMOS_DTB"
)

have_glob() {
  compgen -G "$1" >/dev/null
}

need_tool() {
  local tool="$1"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool: $tool" >&2
    exit 1
  fi
}

need_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "Missing release input: ${path#"$ROOT_DIR/"}" >&2
    exit 1
  fi
}

copy_file() {
  local src="$1"
  local dst="$2"
  mkdir -p "$(dirname "$dst")"
  cp -fL "$src" "$dst"
}

copy_packages() {
  local stage="$1"
  local package base count=0

  mkdir -p "$stage/out/$PROFILE/packages"
  while IFS= read -r -d '' package; do
    base="$(basename "$package")"
    if [[ "$INCLUDE_CAMERA_PACKAGES" != "1" && "$base" == linux-oneplus6t-camera-* ]]; then
      echo "Skipping camera research package for public golden bundle: $base"
      continue
    fi
    cp -fL "$package" "$stage/out/$PROFILE/packages/$base"
    count=$((count + 1))
  done < <(find "$LOCAL_PACKAGE_DIR" -maxdepth 1 \( -type f -o -type l \) \
    \( -name '*.pkg.tar' -o -name '*.pkg.tar.gz' -o -name '*.pkg.tar.xz' -o -name '*.pkg.tar.zst' \) \
    -print0 | sort -z)

  if [[ "$count" -eq 0 ]]; then
    echo "No package artifacts found in: $LOCAL_PACKAGE_DIR" >&2
    exit 1
  fi
}

write_manifest() {
  local stage="$1"
  local manifest="$stage/release-inputs-manifest.txt"

  {
    echo "OnePlus 6T release input bundle"
    echo "profile=$PROFILE"
    echo "created_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    echo "boot_artifacts:"
    printf '  %s\n' "${required_boot_files[@]#"$ROOT_DIR/"}"
    echo
    echo "packages:"
    find "$stage/out/$PROFILE/packages" -maxdepth 1 -type f -printf '  %P\n' | sort
    echo
    echo "optional_payloads:"
    if [[ -d "$stage/vendor/pmos-compat-payload" ]]; then
      echo "  vendor/pmos-compat-payload"
    fi
    if [[ -f "$stage/vendor/pmos-reference/$(basename "$PMOS_HARDWARE_REFERENCE_TARBALL")" ]]; then
      echo "  vendor/pmos-reference/$(basename "$PMOS_HARDWARE_REFERENCE_TARBALL")"
    fi
  } > "$manifest"
}

main() {
  cd "$ROOT_DIR"
  need_tool tar
  need_tool zstd
  need_tool sha256sum

  if [[ ! -d "$PMOS_COMPAT_PAYLOAD_DIR" && -d "$ROOT_DIR/../../pmos-compat-payload" ]]; then
    PMOS_COMPAT_PAYLOAD_DIR="$ROOT_DIR/../../pmos-compat-payload"
  fi

  if [[ ! -f "$PMOS_HARDWARE_REFERENCE_TARBALL" && \
        -f "$ROOT_DIR/../../pmos-reference/pmos-v24.06-oneplus-fajita-hardware-reference.tar.zst" ]]; then
    PMOS_HARDWARE_REFERENCE_TARBALL="$ROOT_DIR/../../pmos-reference/pmos-v24.06-oneplus-fajita-hardware-reference.tar.zst"
  fi

  local path
  for path in "${required_boot_files[@]}"; do
    need_file "$path"
  done

  have_glob "$LOCAL_PACKAGE_DIR/hexagonrpcd-*-aarch64.pkg.tar.*" || {
    echo "Missing staged hexagonrpcd aarch64 package in: $LOCAL_PACKAGE_DIR" >&2
    exit 1
  }
  have_glob "$LOCAL_PACKAGE_DIR/firmware-oneplus-sdm845-[0-9]*-any.pkg.tar.*" || {
    echo "Missing staged firmware-oneplus-sdm845 package in: $LOCAL_PACKAGE_DIR" >&2
    exit 1
  }
  have_glob "$LOCAL_PACKAGE_DIR/firmware-oneplus-sdm845-sensors-*-any.pkg.tar.*" || {
    echo "Missing staged firmware-oneplus-sdm845-sensors package in: $LOCAL_PACKAGE_DIR" >&2
    exit 1
  }

  local tmp asset sha
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/oneplus6t-release-inputs.XXXXXX")"
  RELEASE_INPUTS_TMP="$tmp"
  trap cleanup EXIT

  for path in "${required_boot_files[@]}"; do
    copy_file "$path" "$tmp/vendor/pmos-oneplus-fajita/boot/$(basename "$path")"
  done
  copy_packages "$tmp"

  if [[ -d "$PMOS_COMPAT_PAYLOAD_DIR" ]]; then
    mkdir -p "$tmp/vendor"
    cp -a "$PMOS_COMPAT_PAYLOAD_DIR" "$tmp/vendor/pmos-compat-payload"
  else
    echo "WARN: optional PMOS compatibility payload is missing: ${PMOS_COMPAT_PAYLOAD_DIR#"$ROOT_DIR/"}"
  fi

  if [[ -f "$PMOS_HARDWARE_REFERENCE_TARBALL" ]]; then
    copy_file "$PMOS_HARDWARE_REFERENCE_TARBALL" \
      "$tmp/vendor/pmos-reference/$(basename "$PMOS_HARDWARE_REFERENCE_TARBALL")"
  else
    echo "WARN: optional PMOS hardware reference is missing: ${PMOS_HARDWARE_REFERENCE_TARBALL#"$ROOT_DIR/"}"
  fi

  write_manifest "$tmp"
  (
    cd "$tmp"
    find . -type f ! -name sha256sums.txt -print0 | sort -z | xargs -0 sha256sum > sha256sums.txt
  )

  mkdir -p "$RELEASE_INPUTS_DIR"
  asset="$RELEASE_INPUTS_DIR/$ASSET_NAME"
  tar --zstd -C "$tmp" -cf "$asset" .
  sha="$(sha256sum "$asset" | awk '{print $1}')"
  printf '%s  %s\n' "$sha" "$(basename "$asset")" > "$asset.sha256"

  echo "Release input bundle built:"
  echo "  $asset"
  echo "  $asset.sha256"
  echo
  echo "Upload both files to the GitHub Release used by scripts/fetch-release-inputs.sh."
}

main
