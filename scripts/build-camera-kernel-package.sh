#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${1:-oneplus-fajita}"
PKG_DIR="$ROOT_DIR/packaging/linux-oneplus6t-camera"
OUT_PACKAGE_DIR="${OUT_DIR:-$ROOT_DIR/out/$PROFILE}/packages"

pkgver="$(
  awk -F= '$1 == "pkgver" {print $2; exit}' "$PKG_DIR/PKGBUILD"
)"
pkgrel="$(
  awk -F= '$1 == "pkgrel" {print $2; exit}' "$PKG_DIR/PKGBUILD"
)"
expected_glob="linux-oneplus6t-camera-${pkgver}-${pkgrel}-aarch64.pkg.tar.*"

stage_latest_package() {
  local pkg

  pkg="$(ls -1t "$PKG_DIR"/$expected_glob 2>/dev/null | head -n 1 || true)"
  if [[ -z "$pkg" ]]; then
    echo "No current OnePlus 6T camera kernel package was produced." >&2
    echo "Expected: $expected_glob" >&2
    exit 1
  fi

  "$ROOT_DIR/scripts/stage-local-package.sh" "$PROFILE" "$pkg"
}

if find "$OUT_PACKAGE_DIR" -maxdepth 1 \( -type f -o -type l \) \
  -name "$expected_glob" -print -quit 2>/dev/null | grep -q .; then
  echo "OnePlus 6T camera kernel package already staged."
  exit 0
fi

if ls "$PKG_DIR"/$expected_glob >/dev/null 2>&1; then
  echo "Staging existing OnePlus 6T camera kernel package."
  stage_latest_package
  exit 0
fi

if [[ "$(uname -m)" != "aarch64" ]]; then
  cat >&2 <<'EOF'
The OnePlus 6T camera kernel package must be built in an aarch64 environment.

Build the release on Arch Linux ARM/aarch64, or stage an existing
linux-oneplus6t-camera-*-aarch64.pkg.tar.* package before selecting:
  BOOT_KERNEL_SOURCE=camera-package
EOF
  exit 1
fi

if [[ "$EUID" -eq 0 ]]; then
  echo "Run this as a non-root user; makepkg refuses to run as root." >&2
  exit 1
fi

for tool in makepkg make nproc; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing build tool: $tool" >&2
    exit 1
  fi
done

cd "$PKG_DIR"
makepkg -f --noconfirm
stage_latest_package
