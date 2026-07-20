#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${1:-oneplus-fajita}"
PROFILE_DIR="$ROOT_DIR/profiles/$PROFILE"
PKG_DIR="$ROOT_DIR/packaging/hexagonrpcd"
OUT_PACKAGE_DIR="${OUT_DIR:-$ROOT_DIR/out/$PROFILE}/packages"

if [[ -f "$PROFILE_DIR/config.env" ]]; then
  # shellcheck source=/dev/null
  source "$PROFILE_DIR/config.env"
fi

stage_latest_package() {
  local pkg

  pkg="$(ls -1t "$PKG_DIR"/hexagonrpcd-*-aarch64.pkg.tar.* 2>/dev/null | head -n 1 || true)"
  if [[ -z "$pkg" ]]; then
    echo "No hexagonrpcd aarch64 package was produced." >&2
    exit 1
  fi

  "$ROOT_DIR/scripts/stage-local-package.sh" "$PROFILE" "$pkg"
}

if find "$OUT_PACKAGE_DIR" -maxdepth 1 \( -type f -o -type l \) \
  -name 'hexagonrpcd-*-aarch64.pkg.tar.*' -print -quit 2>/dev/null | grep -q .; then
  echo "hexagonrpcd package already staged."
  exit 0
fi

if ls "$PKG_DIR"/hexagonrpcd-*-aarch64.pkg.tar.* >/dev/null 2>&1; then
  echo "Staging existing hexagonrpcd aarch64 package."
  stage_latest_package
  exit 0
fi

if [[ "$(uname -m)" != "aarch64" ]]; then
  cat >&2 <<'EOF'
hexagonrpcd must be built in an aarch64 environment.

Build this installer on Arch Linux ARM/aarch64, or stage an existing
hexagonrpcd-*-aarch64.pkg.tar.* package before running build-release.sh.
EOF
  exit 1
fi

if [[ "$EUID" -eq 0 ]]; then
  echo "Run this as a non-root user; makepkg refuses to run as root." >&2
  exit 1
fi

for tool in makepkg meson ninja arch-meson; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing build tool: $tool" >&2
    exit 1
  fi
done

cd "$PKG_DIR"
makepkg -f --noconfirm
stage_latest_package
