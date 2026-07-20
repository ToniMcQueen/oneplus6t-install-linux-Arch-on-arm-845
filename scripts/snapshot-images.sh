#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${1:-oneplus-fajita}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/out/$PROFILE}"
SNAPSHOT_ROOT="${SNAPSHOT_ROOT:-$ROOT_DIR/image-snapshots}"
TAG="${TAG:-manual}"
INCLUDE_RAW="${INCLUDE_RAW:-0}"
ALLOW_FULL_COPY="${ALLOW_FULL_COPY:-0}"
MANIFEST_ONLY_ON_LINK_FAIL="${MANIFEST_ONLY_ON_LINK_FAIL:-0}"
MOVE_SOURCE="${MOVE_SOURCE:-0}"

safe_tag() {
  printf '%s' "$1" | tr -cs 'A-Za-z0-9._+-' '-'
}

require_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "Missing required file: $path" >&2
    exit 1
  fi
}

snapshot_copy() {
  local src="$1"
  local dest="$2"

  if [[ "$MOVE_SOURCE" == "1" ]]; then
    mv "$src" "$dest"
    printf 'move'
    return
  fi

  if cp --reflink=always --sparse=always --preserve=mode,timestamps "$src" "$dest" 2>/dev/null; then
    printf 'reflink'
    return
  fi

  if ln "$src" "$dest" 2>/dev/null; then
    printf 'hardlink'
    return
  fi

  if [[ "$ALLOW_FULL_COPY" == "1" ]]; then
    cp --sparse=always --preserve=mode,timestamps "$src" "$dest"
    printf 'copy'
    return
  fi

  if [[ "$MANIFEST_ONLY_ON_LINK_FAIL" == "1" ]]; then
    printf 'manifest-only'
    return
  fi

  cat >&2 <<EOF
Could not create a reflink or hardlink for:
  $src

Refusing a full copy because space is tight. To force a real copy, rerun with:
  ALLOW_FULL_COPY=1
EOF
  exit 1
}

write_manifest_row() {
  local label="$1"
  local path="$2"
  local method="$3"
  local file_name="${4:-$(basename "$path")}"
  local hash
  local bytes
  local disk_usage
  local inode

  hash="$(sha256sum "$path" | awk '{ print $1 }')"
  bytes="$(stat -c '%s' "$path")"
  disk_usage="$(du -h "$path" | awk '{ print $1 }')"
  inode="$(stat -c '%i' "$path")"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$label" "$file_name" "$hash" "$bytes" "$disk_usage" "$inode" "$method" \
    >> "$SNAP_DIR/manifest.tsv"
}

snapshot_artifact() {
  local label="$1"
  local src="$2"
  local dest="$3"
  local method

  method="$(snapshot_copy "$src" "$dest")"
  if [[ "$method" == "manifest-only" ]]; then
    write_manifest_row "$label" "$src" "$method" "$(basename "$dest")"
    cat > "$dest.NOT_STORED.txt" <<EOF
The image data was not stored in this snapshot.

Source file:
  $src

Reason:
  reflink/hardlink failed, and full copy was disabled.

The hash and metadata are still recorded in manifest.tsv.
EOF
  else
    write_manifest_row "$label" "$dest" "$method"
  fi
}

BOOT_IMG="$OUT_DIR/oneplus6t-arch-boot.img"
ROOT_IMG="$OUT_DIR/oneplus6t-arch-root.img"
RAW_IMG="$OUT_DIR/oneplus6t-arch-root.raw.img"
BOOT_SUM="$BOOT_IMG.sha256"
ROOT_SUM="$ROOT_IMG.sha256"

require_file "$BOOT_IMG"
require_file "$ROOT_IMG"
require_file "$BOOT_SUM"
require_file "$ROOT_SUM"

sha256sum -c "$BOOT_SUM"
sha256sum -c "$ROOT_SUM"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
SNAP_DIR="$SNAPSHOT_ROOT/$timestamp-$(safe_tag "$TAG")"
mkdir -p "$SNAP_DIR"

{
  printf 'profile\t%s\n' "$PROFILE"
  printf 'tag\t%s\n' "$TAG"
  printf 'created_utc\t%s\n' "$timestamp"
  printf 'source_out_dir\t%s\n' "$OUT_DIR"
  printf 'git_head\t%s\n' "$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || printf unknown)"
  printf 'git_dirty\t%s\n' "$(git -C "$ROOT_DIR" status --short 2>/dev/null | wc -l | tr -d ' ')"
} > "$SNAP_DIR/snapshot-info.tsv"

printf 'label\tfile\tsha256\tbytes\tdu\tinode\tmethod\n' > "$SNAP_DIR/manifest.tsv"

snapshot_artifact boot "$BOOT_IMG" "$SNAP_DIR/oneplus6t-arch-boot.img"
cp "$BOOT_SUM" "$SNAP_DIR/oneplus6t-arch-boot.img.sha256"

snapshot_artifact root "$ROOT_IMG" "$SNAP_DIR/oneplus6t-arch-root.img"
cp "$ROOT_SUM" "$SNAP_DIR/oneplus6t-arch-root.img.sha256"

if [[ "$INCLUDE_RAW" == "1" ]]; then
  require_file "$RAW_IMG"
  snapshot_artifact raw "$RAW_IMG" "$SNAP_DIR/oneplus6t-arch-root.raw.img"
fi

ln -sfn "$(basename "$SNAP_DIR")" "$SNAPSHOT_ROOT/latest"

cat > "$SNAP_DIR/README.md" <<EOF
# OnePlus 6T Image Snapshot

Tag: \`$TAG\`

Created UTC: \`$timestamp\`

This directory stores the flashable boot/root pair from:

\`\`\`text
$OUT_DIR
\`\`\`

Files were stored with reflinks or hardlinks where possible to avoid consuming
another full copy of the image data.

When the snapshot method is `move`, the previous artifact was atomically moved
out of `out/` so the next build can replace it without allocating a duplicate.

Use \`manifest.tsv\` for hashes and file metadata.
EOF

echo "Created image snapshot:"
echo "$SNAP_DIR"
echo
cat "$SNAP_DIR/manifest.tsv"
