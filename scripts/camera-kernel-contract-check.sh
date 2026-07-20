#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_DIR="$ROOT_DIR/packaging/linux-oneplus6t-camera"
PROFILE_DIR="$ROOT_DIR/profiles/oneplus-fajita"

fail() {
  printf 'camera-kernel-contract-check: %s\n' "$*" >&2
  exit 1
}

need_file() {
  [[ -f "$1" ]] || fail "missing file: ${1#"$ROOT_DIR/"}"
}

need_executable() {
  [[ -x "$1" ]] || fail "missing executable: ${1#"$ROOT_DIR/"}"
}

need_text() {
  grep -Fq -- "$2" "$1" || fail "missing text in ${1#"$ROOT_DIR/"}: $2"
}

need_pkgbuild_checksum() {
  local file="$1"
  local digest
  digest="$(sha256sum "$file" | awk '{print $1}')"
  need_text "$PKG_DIR/PKGBUILD" "'$digest'"
}

need_file "$PKG_DIR/PKGBUILD"
need_file "$PKG_DIR/camera.config"
need_file "$PKG_DIR/hibernate.config"
need_file "$PKG_DIR/camera-series.tsv"
need_file "$PKG_DIR/0001-media-qcom-camss-set-csid-cphy-bit.patch"
need_file "$PKG_DIR/0002-media-qcom-camss-bound-sdm845-cphy-lane-table.patch"
need_file "$PKG_DIR/0003-media-qcom-camss-add-oneplus6t-imx519-diagnostics.patch"
need_file "$PKG_DIR/0004-media-qcom-camss-add-oneplus6t-cphy-lab-overrides.patch"
need_file "$PKG_DIR/0005-media-i2c-imx519-add-oneplus6t-stream-readbacks.patch"
need_file "$PKG_DIR/0007-media-qcom-camss-add-oneplus6t-runtime-state-dumps.patch"
need_file "$PKG_DIR/0008-media-qcom-camss-log-oneplus6t-csiphy-state.patch"
need_file "$PROFILE_DIR/camera-packages.txt"
need_executable "$ROOT_DIR/scripts/build-camera-kernel-package.sh"
need_executable "$PROFILE_DIR/overlay/usr/local/bin/oneplus6t-camera-info"

need_text "$PKG_DIR/PKGBUILD" "_commit=26f9dfad4030de634dbf50f398f95281c29c3965"
need_text "$PKG_DIR/PKGBUILD" "pkgrel=12"
need_text "$PKG_DIR/PKGBUILD" "0001-media-qcom-camss-set-csid-cphy-bit.patch"
need_text "$PKG_DIR/PKGBUILD" "0002-media-qcom-camss-bound-sdm845-cphy-lane-table.patch"
need_text "$PKG_DIR/PKGBUILD" "0003-media-qcom-camss-add-oneplus6t-imx519-diagnostics.patch"
need_text "$PKG_DIR/PKGBUILD" "0004-media-qcom-camss-add-oneplus6t-cphy-lab-overrides.patch"
need_text "$PKG_DIR/PKGBUILD" "0005-media-i2c-imx519-add-oneplus6t-stream-readbacks.patch"
need_text "$PKG_DIR/PKGBUILD" "0007-media-qcom-camss-add-oneplus6t-runtime-state-dumps.patch"
need_text "$PKG_DIR/PKGBUILD" "0008-media-qcom-camss-log-oneplus6t-csiphy-state.patch"
need_text "$PKG_DIR/PKGBUILD" "hibernate.config"
need_pkgbuild_checksum "$PKG_DIR/camera.config"
need_pkgbuild_checksum "$PKG_DIR/hibernate.config"
need_pkgbuild_checksum "$PKG_DIR/camera-series.tsv"
need_pkgbuild_checksum "$PKG_DIR/0002-media-qcom-camss-bound-sdm845-cphy-lane-table.patch"
need_pkgbuild_checksum "$PKG_DIR/0003-media-qcom-camss-add-oneplus6t-imx519-diagnostics.patch"
need_pkgbuild_checksum "$PKG_DIR/0004-media-qcom-camss-add-oneplus6t-cphy-lab-overrides.patch"
need_pkgbuild_checksum "$PKG_DIR/0005-media-i2c-imx519-add-oneplus6t-stream-readbacks.patch"
need_pkgbuild_checksum "$PKG_DIR/0007-media-qcom-camss-add-oneplus6t-runtime-state-dumps.patch"
need_pkgbuild_checksum "$PKG_DIR/0008-media-qcom-camss-log-oneplus6t-csiphy-state.patch"
need_text "$PKG_DIR/0004-media-qcom-camss-add-oneplus6t-cphy-lab-overrides.patch" "oneplus6t_cphy_lane_assign"
need_text "$PKG_DIR/0004-media-qcom-camss-add-oneplus6t-cphy-lab-overrides.patch" "oneplus6t_cphy_active_lanes"
need_text "$PKG_DIR/0004-media-qcom-camss-add-oneplus6t-cphy-lab-overrides.patch" "oneplus6t_cphy_ctrl5"
need_text "$PKG_DIR/0004-media-qcom-camss-add-oneplus6t-cphy-lab-overrides.patch" "oneplus6t_cphy_settle"
need_text "$PKG_DIR/0005-media-i2c-imx519-add-oneplus6t-stream-readbacks.patch" "oneplus6t_force_common_regs"
need_text "$PKG_DIR/0005-media-i2c-imx519-add-oneplus6t-stream-readbacks.patch" "oneplus6t_stream_on_delay_ms"
need_text "$PKG_DIR/0005-media-i2c-imx519-add-oneplus6t-stream-readbacks.patch" "oneplus6t_stream_readback"
need_text "$PKG_DIR/0007-media-qcom-camss-add-oneplus6t-runtime-state-dumps.patch" "csid_oneplus6t_dump_state"
need_text "$PKG_DIR/0007-media-qcom-camss-add-oneplus6t-runtime-state-dumps.patch" "oneplus6t-vfe"
need_text "$PKG_DIR/0008-media-qcom-camss-log-oneplus6t-csiphy-state.patch" "csiphy_oneplus6t_log_clock_state"
need_text "$PKG_DIR/0008-media-qcom-camss-log-oneplus6t-csiphy-state.patch" "oneplus6t-camss: csiphy%u state"
need_text "$PKG_DIR/camera.config" "CONFIG_VIDEO_QCOM_CAMSS=m"
need_text "$PKG_DIR/camera.config" "CONFIG_VIDEO_IMX371=m"
need_text "$PKG_DIR/camera.config" "CONFIG_VIDEO_IMX376=m"
need_text "$PKG_DIR/camera.config" "CONFIG_VIDEO_IMX519=m"
need_text "$PKG_DIR/camera.config" "CONFIG_NFC_NXP_NCI=m"
need_text "$PKG_DIR/camera.config" "CONFIG_NFC_NXP_NCI_I2C=m"
need_text "$PKG_DIR/camera.config" "# CONFIG_CIFS is not set"
need_text "$PKG_DIR/hibernate.config" "CONFIG_HIBERNATION=y"
need_text "$PKG_DIR/config-postmarketos-qcom-sdm845.aarch64" "CONFIG_ARCH_HIBERNATION_POSSIBLE=y"
need_text "$PKG_DIR/config-postmarketos-qcom-sdm845.aarch64" "CONFIG_SWAP=y"
need_text "$PKG_DIR/config-postmarketos-qcom-sdm845.aarch64" "# CONFIG_HIBERNATION is not set"
need_text "$PKG_DIR/camera-series.tsv" "635de40b6689710ee2af89dc0399e52d15c00894"
need_text "$PKG_DIR/camera-series.tsv" "local-0001"
need_text "$PKG_DIR/camera-series.tsv" "local-0002"
need_text "$PKG_DIR/camera-series.tsv" "local-0003"
need_text "$PKG_DIR/camera-series.tsv" "local-0004"
need_text "$PKG_DIR/camera-series.tsv" "local-0005"
need_text "$PKG_DIR/camera-series.tsv" "local-0007"
need_text "$PKG_DIR/camera-series.tsv" "local-0008"
need_text "$PROFILE_DIR/config.env" 'BOOT_KERNEL_SOURCE="${BOOT_KERNEL_SOURCE:-pmos-snapshot}"'
need_text "$ROOT_DIR/scripts/build-release.sh" 'BOOT_KERNEL_SOURCE:-pmos-snapshot'
need_text "$ROOT_DIR/scripts/build-bootimg.sh" 'camera-package)'
need_text "$ROOT_DIR/scripts/build-rootfs-image.sh" 'require_camera_kernel_package'
need_text "$ROOT_DIR/scripts/build-rootfs-image.sh" 'remove_conflicting_stock_kernel'
need_text "$ROOT_DIR/scripts/build-rootfs-image.sh" '-Rdd linux-aarch64'
need_text "$PROFILE_DIR/camera-packages.txt" "libcamera"
need_text "$PROFILE_DIR/camera-packages.txt" "libcamera-tools"
need_text "$PROFILE_DIR/camera-packages.txt" "v4l-utils"

for script in \
  "$ROOT_DIR/scripts/build-camera-kernel-package.sh" \
  "$ROOT_DIR/scripts/build-bootimg.sh" \
  "$ROOT_DIR/scripts/build-release.sh" \
  "$ROOT_DIR/scripts/build-rootfs-image.sh" \
  "$PROFILE_DIR/overlay/usr/local/bin/oneplus6t-camera-info"; do
  bash -n "$script"
done

prepared="$PKG_DIR/src/linux-26f9dfad4030de634dbf50f398f95281c29c3965"
if [[ -d "$prepared" ]]; then
  need_text "$prepared/.config" "CONFIG_VIDEO_IMX519=m"
  need_text "$prepared/drivers/media/platform/qcom/camss/camss-csid-gen2.c" \
    'cfg0 |= 1 << CSI2_RX_CFG0_PHY_TYPE_SEL;'
fi

printf 'camera-kernel-contract-check: passed\n'
