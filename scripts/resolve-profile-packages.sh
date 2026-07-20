#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${1:-oneplus-fajita}"
PROFILE_DIR="$ROOT_DIR/profiles/$PROFILE"

usage() {
  cat <<EOF
Usage: scripts/resolve-profile-packages.sh [profile] [--download]

Resolves the Arch Linux ARM aarch64 package closure listed in:
  profiles/<profile>/packages.txt

By default this writes package URLs to:
  out/<profile>/alarm-package-urls.txt

With --download it downloads the packages into:
  cache/alarm-packages/pkg
EOF
}

DOWNLOAD=0
if [[ "${2:-}" == "--download" ]]; then
  DOWNLOAD=1
elif [[ "${1:-}" == "--help" || "${2:-}" == "--help" ]]; then
  usage
  exit 0
elif [[ $# -gt 2 ]]; then
  usage >&2
  exit 1
fi

if [[ ! -f "$PROFILE_DIR/config.env" ]]; then
  echo "Missing profile config: $PROFILE_DIR/config.env" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$PROFILE_DIR/config.env"

# shellcheck source=scripts/package-name-aliases.sh
source "$ROOT_DIR/scripts/package-name-aliases.sh"

PACKAGES_FILE="${PACKAGES_FILE:-$PROFILE_DIR/packages.txt}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/out/$PROFILE}"
CACHE_DIR="${CACHE_DIR:-$ROOT_DIR/cache}"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/work/$PROFILE/package-resolver}"
PACMAN_DB_DIR="$WORK_DIR/pacman-db"
PACMAN_CACHE_DIR="$CACHE_DIR/alarm-packages/pkg"
PACMAN_CONF="$WORK_DIR/pacman-aarch64.conf"
URLS_OUT="$OUT_DIR/alarm-package-urls.txt"
PACKAGE_LIST_OUT="$OUT_DIR/alarm-package-list.txt"

if [[ ! -f "$PACKAGES_FILE" ]]; then
  echo "Missing package manifest: $PACKAGES_FILE" >&2
  exit 1
fi

if ! command -v pacman >/dev/null 2>&1; then
  echo "Missing required tool: pacman" >&2
  exit 1
fi

mapfile -t PACKAGES < <(awk '
  /^[[:space:]]*($|#)/ { next }
  { print $1 }
' "$PACKAGES_FILE" | while IFS= read -r package; do
  normalize_profile_package_name "$package"
done | awk '!seen[$1]++ { print $1 }')

if [[ "${#PACKAGES[@]}" -eq 0 ]]; then
  echo "No packages listed in: $PACKAGES_FILE" >&2
  exit 1
fi

mkdir -p "$OUT_DIR" "$WORK_DIR" "$PACMAN_DB_DIR" "$PACMAN_CACHE_DIR"

cat > "$PACMAN_CONF" <<'EOF'
[options]
Architecture = aarch64
SigLevel = Never
LocalFileSigLevel = Never
ParallelDownloads = 5

[core]
Server = http://mirror.archlinuxarm.org/$arch/$repo

[extra]
Server = http://mirror.archlinuxarm.org/$arch/$repo

[alarm]
Server = http://mirror.archlinuxarm.org/$arch/$repo

[aur]
Server = http://mirror.archlinuxarm.org/$arch/$repo
EOF

PACMAN=(
  pacman
  --config "$PACMAN_CONF"
  --dbpath "$PACMAN_DB_DIR"
  --cachedir "$PACMAN_CACHE_DIR"
  --logfile "$WORK_DIR/pacman.log"
  --noconfirm
)

printf '%s\n' "${PACKAGES[@]}" > "$PACKAGE_LIST_OUT"

"${PACMAN[@]}" -Sy

if [[ "$DOWNLOAD" -eq 1 ]]; then
  "${PACMAN[@]}" -Sw --needed "${PACKAGES[@]}"
  find "$PACMAN_CACHE_DIR" -maxdepth 1 -type f -name '*.pkg.tar.*' -printf '%p\n' \
    | sort > "$OUT_DIR/alarm-downloaded-packages.txt"
  echo "Downloaded package files:"
  echo "$OUT_DIR/alarm-downloaded-packages.txt"
else
  "${PACMAN[@]}" -Sp --print-format '%l' --needed "${PACKAGES[@]}" \
    | sort -u > "$URLS_OUT"
  echo "Resolved package URLs:"
  echo "$URLS_OUT"
fi
