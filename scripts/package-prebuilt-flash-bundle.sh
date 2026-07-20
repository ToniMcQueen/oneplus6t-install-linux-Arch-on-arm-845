#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  PROFILE="${2:-oneplus-fajita}"
else
  PROFILE="${1:-oneplus-fajita}"
fi
OUT_DIR="${OUT_DIR:-$ROOT_DIR/out/$PROFILE}"
PREBUILT_DIR="${PREBUILT_DIR:-$ROOT_DIR/out/prebuilt}"
TAG="${TAG:-$(date -u +%Y%m%dT%H%M%SZ)}"
SAFE_TAG="${TAG//[^A-Za-z0-9._-]/-}"
BUNDLE_NAME="${BUNDLE_NAME:-oneplus6t-archlinux-prebuilt-$PROFILE-$SAFE_TAG}"
mkdir -p "$PREBUILT_DIR"
STAGE_DIR="$(mktemp -d "$PREBUILT_DIR/.${BUNDLE_NAME}.stage.XXXXXX")"
ARCHIVE="$PREBUILT_DIR/$BUNDLE_NAME.tar.zst"
ARCHIVE_SUM="$ARCHIVE.sha256"

BOOT_IMG="$OUT_DIR/oneplus6t-arch-boot.img"
ROOT_IMG="$OUT_DIR/oneplus6t-arch-root.img"
BOOT_SUM="$BOOT_IMG.sha256"
ROOT_SUM="$ROOT_IMG.sha256"

cleanup() {
  rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

usage() {
  cat <<EOF
Usage: TAG=name $0 [profile]

Packages an already-built OnePlus 6T boot/root pair into a hostable archive.
Run this after the installer or scripts/build-release.sh has produced:
  $BOOT_IMG
  $ROOT_IMG

Output:
  $ARCHIVE
  $ARCHIVE_SUM
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

for tool in sha256sum tar zstd date mktemp; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool: $tool" >&2
    exit 1
  fi
done

for path in "$BOOT_IMG" "$ROOT_IMG" "$BOOT_SUM" "$ROOT_SUM"; do
  if [[ ! -f "$path" ]]; then
    echo "Missing required build artifact: $path" >&2
    echo "Build first with:" >&2
    echo "  scripts/run-full-installer-from-start.sh $PROFILE" >&2
    exit 1
  fi
done

echo "Verifying current release artifacts."
sha256sum -c "$BOOT_SUM"
sha256sum -c "$ROOT_SUM"

mkdir -p "$STAGE_DIR/$BUNDLE_NAME/out/$PROFILE" "$STAGE_DIR/$BUNDLE_NAME/scripts"

cp -f "$BOOT_IMG" "$STAGE_DIR/$BUNDLE_NAME/out/$PROFILE/"
cp -f "$ROOT_IMG" "$STAGE_DIR/$BUNDLE_NAME/out/$PROFILE/"
cp -f scripts/check-phone.sh "$STAGE_DIR/$BUNDLE_NAME/scripts/"
cp -f scripts/flash-release.sh "$STAGE_DIR/$BUNDLE_NAME/scripts/"
cp -f scripts/fastboot-userdata-preflight.sh "$STAGE_DIR/$BUNDLE_NAME/scripts/"
cp -f scripts/android-sparse-info.py "$STAGE_DIR/$BUNDLE_NAME/scripts/"
chmod +x "$STAGE_DIR/$BUNDLE_NAME/scripts/check-phone.sh" \
  "$STAGE_DIR/$BUNDLE_NAME/scripts/flash-release.sh" \
  "$STAGE_DIR/$BUNDLE_NAME/scripts/fastboot-userdata-preflight.sh"

cat > "$STAGE_DIR/$BUNDLE_NAME/flash-prebuilt-oneplus6t.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

PROFILE="${PROFILE:-oneplus-fajita}"

echo "OnePlus 6T prebuilt flash bundle"
echo
echo "This is destructive: it flashes boot and userdata."
echo "The phone must already have an unlocked bootloader and be in fastboot mode."
echo

./scripts/check-phone.sh
echo
echo "Ready to flash this prebuilt bundle."
echo "Type FLASH to write boot + userdata now, or press Enter to stop:"
read -r confirm
if [[ "$confirm" != "FLASH" ]]; then
  echo "Stopped before flashing."
  exit 0
fi

CONFIRM_FLASH=1 \
USERDATA_PREFLIGHT="${USERDATA_PREFLIGHT:-strict}" \
FASTBOOT_SPARSE_SIZE="${FASTBOOT_SPARSE_SIZE:-16M}" \
DISABLE_ANDROID_VERIFICATION="${DISABLE_ANDROID_VERIFICATION:-1}" \
"$ROOT_DIR/scripts/flash-release.sh" "$PROFILE"
EOF
chmod +x "$STAGE_DIR/$BUNDLE_NAME/flash-prebuilt-oneplus6t.sh"

cat > "$STAGE_DIR/$BUNDLE_NAME/README-prebuilt.md" <<EOF
# OnePlus 6T Prebuilt Flash Bundle

Profile: \`$PROFILE\`
Source commit: \`$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)\`
Built package tag: \`$SAFE_TAG\`
Created UTC: \`$(date -u +%Y-%m-%dT%H:%M:%SZ)\`

This bundle contains an already-built boot/root pair:

- \`out/$PROFILE/oneplus6t-arch-boot.img\`
- \`out/$PROFILE/oneplus6t-arch-root.img\`

The phone must already be bootloader-unlocked and in fastboot mode.

Flash from the extracted bundle:

\`\`\`sh
./flash-prebuilt-oneplus6t.sh
\`\`\`

If a flash fails after the images are already extracted and the phone is back
in fastboot mode, resume without rebuilding:

\`\`\`sh
CONFIRM_FLASH=1 USERDATA_PREFLIGHT=strict FASTBOOT_SPARSE_SIZE=16M DISABLE_ANDROID_VERIFICATION=1 scripts/flash-release.sh $PROFILE
\`\`\`
EOF

(
  cd "$STAGE_DIR/$BUNDLE_NAME"
  sha256sum "out/$PROFILE/oneplus6t-arch-boot.img" > "out/$PROFILE/oneplus6t-arch-boot.img.sha256"
  sha256sum "out/$PROFILE/oneplus6t-arch-root.img" > "out/$PROFILE/oneplus6t-arch-root.img.sha256"
)

cat > "$STAGE_DIR/$BUNDLE_NAME/manifest.txt" <<EOF
bundle=$BUNDLE_NAME
profile=$PROFILE
tag=$SAFE_TAG
source_commit=$(git rev-parse HEAD 2>/dev/null || echo unknown)
created_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
boot_image=out/$PROFILE/oneplus6t-arch-boot.img
root_image=out/$PROFILE/oneplus6t-arch-root.img
flash_script=flash-prebuilt-oneplus6t.sh
EOF

rm -f "$ARCHIVE" "$ARCHIVE_SUM"

echo "Creating hostable prebuilt bundle:"
echo "  $ARCHIVE"
tar --zstd -C "$STAGE_DIR" -cf "$ARCHIVE" "$BUNDLE_NAME"
sha256sum "$ARCHIVE" > "$ARCHIVE_SUM"

echo
echo "Prebuilt bundle ready:"
echo "  $ARCHIVE"
echo "  $ARCHIVE_SUM"
echo
echo "Website upload files:"
echo "  $(basename "$ARCHIVE")"
echo "  $(basename "$ARCHIVE_SUM")"
