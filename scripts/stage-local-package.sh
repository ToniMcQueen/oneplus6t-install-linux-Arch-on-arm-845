#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: scripts/stage-local-package.sh PROFILE PACKAGE [PACKAGE...]

Symlink local aarch64 package artifacts into out/PROFILE/packages so the
rootfs builder can inject them without copying package data.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || "$#" -lt 2 ]]; then
  usage
  exit 0
fi

PROFILE="$1"
shift

DEST="$ROOT_DIR/out/$PROFILE/packages"
mkdir -p "$DEST"

for pkg in "$@"; do
  if [[ ! -f "$pkg" ]]; then
    echo "Package not found: $pkg" >&2
    exit 1
  fi

  pkg_abs="$(realpath "$pkg")"
  ln -sfn "$pkg_abs" "$DEST/$(basename "$pkg")"
  echo "staged: $DEST/$(basename "$pkg") -> $pkg_abs"
done
