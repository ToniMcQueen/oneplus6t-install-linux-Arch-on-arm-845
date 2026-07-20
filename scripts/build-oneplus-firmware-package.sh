#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${1:-oneplus-fajita}"
PKG_DIR="$ROOT_DIR/packaging/firmware-oneplus-sdm845"

if [[ "$EUID" -eq 0 ]]; then
  echo "Run this as a non-root user; makepkg refuses to run as root." >&2
  exit 1
fi

if ! command -v makepkg >/dev/null 2>&1; then
  echo "Missing build tool: makepkg" >&2
  exit 1
fi

cd "$PKG_DIR"
makepkg -f --nodeps --noconfirm

pkg="$(ls -1t "$PKG_DIR"/firmware-oneplus-sdm845-*-any.pkg.tar.* | head -n 1)"
"$ROOT_DIR/scripts/stage-local-package.sh" "$PROFILE" "$pkg"
