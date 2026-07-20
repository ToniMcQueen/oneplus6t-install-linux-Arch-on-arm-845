#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${1:-oneplus-fajita}"

# shellcheck source=scripts/lib/privilege.sh
source "$ROOT_DIR/scripts/lib/privilege.sh"

cd "$ROOT_DIR"

echo "OnePlus 6T full public installer run from start"
echo
echo "This wrapper verifies the repo and fastboot state, then rebuilds and flashes"
echo "the public stable-default image through the strict path."
echo
echo "This runs the reproducible public path:"
echo "  - clean committed installer tree required"
echo "  - source submodules initialized before validation"
echo "  - release input bundle fetched and verified before build"
echo "  - no personal SSH key embedding"
echo "  - optional username, Wi-Fi, APN, and local password prompts"
echo "  - stable PMOS kernel by default, explicit opt-in camera kernel test track"
echo "  - optional boot intro choice: bundled video, custom video, or verbose boot"
echo "  - temporary root/user password defaults if password prompts are left blank"
echo "  - public auto-rotate/sensor/radio defaults"
echo "  - interactive package review before rootfs build"
echo "  - root image virtual size detected from fastboot userdata"
echo "  - strict userdata preflight before destructive flash"
echo "  - one direct Btrfs userdata flash pass after the size check"
echo "  - no default fastboot erase before userdata"
echo "  - no ext4 clean-stage unless explicitly enabled for lab recovery"
echo "  - PMOS-style 16M fastboot sparse chunks by default"
echo "  - disabled active-slot vbmeta before flashing the custom boot image"
echo "  - timed caller-owned fastboot reboot, then manual fallback if needed"
echo

echo "== Current commit =="
git log -1 --oneline
echo

echo "== Submodule check =="
if git submodule status --recursive | grep -Eq '^-'; then
  echo "Initializing missing source submodules."
  git submodule update --init --recursive
fi
git submodule status --recursive
echo

echo "== Release input check =="
scripts/fetch-release-inputs.sh \
  --profile "$PROFILE" \
  --tag "${RELEASE_INPUTS_TAG:-latest}"
echo

echo "== Clean tree check =="
if [[ -n "$(git status --porcelain)" ]]; then
  git status --short
  echo "Refusing to run strict public build from a dirty tree." >&2
  exit 1
fi
git status --short --branch
echo

echo "== Script syntax + UI contract check =="
bash -n scripts/build-rootfs-image.sh
bash -n scripts/build-bootimg.sh
bash -n scripts/build-release.sh
bash -n scripts/flash-release.sh
bash -n scripts/install-release.sh
bash -n scripts/review-profile-packages.sh
bash -n scripts/phone-smoke-report.sh
bash -n scripts/profile-ui-check.sh
scripts/profile-ui-check.sh "$PROFILE"
echo

echo "== Flash default sanity check =="
grep -n 'ERASE_USERDATA_BEFORE_FLASH="${ERASE_USERDATA_BEFORE_FLASH:-0}"' scripts/flash-release.sh
grep -n 'EXT4_CLEANSTAGE_BEFORE_BTRFS="${EXT4_CLEANSTAGE_BEFORE_BTRFS:-0}"' scripts/flash-release.sh
grep -n 'ROOT_FLASH_PASSES="${ROOT_FLASH_PASSES:-1}"' scripts/flash-release.sh
grep -n 'FASTBOOT_SPARSE_SIZE="${FASTBOOT_SPARSE_SIZE:-16M}"' scripts/flash-release.sh
grep -n 'USERDATA_PREFLIGHT="${USERDATA_PREFLIGHT:-warn}"' scripts/flash-release.sh
grep -n 'DISABLE_ANDROID_VERIFICATION="${DISABLE_ANDROID_VERIFICATION:-1}"' scripts/flash-release.sh
grep -n 'FASTBOOT_REBOOT_MODE="${FASTBOOT_REBOOT_MODE:-timeout}"' scripts/flash-release.sh
grep -n 'FASTBOOT_REBOOT_FALLBACK="${FASTBOOT_REBOOT_FALLBACK:-reboot}"' scripts/flash-release.sh
grep -n 'FASTBOOT_REBOOT_AS_CALLER="${FASTBOOT_REBOOT_AS_CALLER:-1}"' scripts/flash-release.sh
echo

echo "== Fastboot visibility =="
echo "If no device is printed below, stop and put the phone in fastboot mode."
timeout 8 fastboot devices -l || true
echo

echo "== privilege warm-up =="
echo "The root image builder creates and mounts a Btrfs loop image."
echo "This host must provide one usable privilege path: doas, sudo, su, or root."
if ! require_root_runner; then
  exit 1
fi
case "${ROOT_RUNNER_MODE:-root}" in
  doas)
    echo "Using doas for root image build and fastboot flash."
    echo "Enter your laptop password once now if prompted."
    doas true
    ;;
  sudo)
    echo "Using sudo for root image build and fastboot flash."
    echo "Enter your laptop password once now if prompted."
    sudo -v
    ;;
  su)
    echo "Using su for root image build and fastboot flash."
    echo "You will be prompted for the root password during build/flash."
    ;;
  *)
    echo "Already running as root."
    ;;
esac
echo

exec scripts/install-release.sh "$PROFILE"
