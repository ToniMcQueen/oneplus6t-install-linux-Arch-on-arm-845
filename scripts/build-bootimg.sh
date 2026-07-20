#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${1:-oneplus-fajita}"
PROFILE_DIR="$ROOT_DIR/profiles/$PROFILE"

if [[ ! -f "$PROFILE_DIR/config.env" ]]; then
  echo "Missing profile config: $PROFILE_DIR/config.env" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$PROFILE_DIR/config.env"

# shellcheck source=scripts/lib/privilege.sh
source "$ROOT_DIR/scripts/lib/privilege.sh"

OUT_DIR="${OUT_DIR:-$ROOT_DIR/out/$PROFILE}"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/work/$PROFILE/bootimg}"
LOCAL_PACKAGE_DIR="${LOCAL_PACKAGE_DIR:-$OUT_DIR/packages}"
mkdir -p "$OUT_DIR" "$WORK_DIR"

for tool in mkbootimg sha256sum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool: $tool" >&2
    exit 1
  fi
done

remove_build_path() {
  local path="$1"

  if [[ ! -e "$path" && ! -L "$path" ]]; then
    return
  fi

  if rm -rf "$path" 2>/dev/null; then
    return
  fi

  echo "Normal cleanup could not remove $path; retrying with root privileges."
  run_as_root rm -rf "$path"
}

select_newest_camera_package() {
  local package
  local package_info
  local package_name
  local package_version
  local selected_package=""
  local selected_version=""

  if ! command -v pacman >/dev/null 2>&1; then
    echo "Missing required tool for camera package selection: pacman" >&2
    exit 1
  fi
  if ! command -v vercmp >/dev/null 2>&1; then
    echo "Missing required tool for camera package selection: vercmp" >&2
    exit 1
  fi

  while IFS= read -r -d '' package; do
    package_info="$(pacman -Qp "$package")"
    package_name="${package_info%% *}"
    package_version="${package_info#* }"

    if [[ "$package_name" != "linux-oneplus6t-camera" ]]; then
      continue
    fi

    if [[ -z "$selected_package" || $(vercmp "$package_version" "$selected_version") -gt 0 ]]; then
      selected_package="$package"
      selected_version="$package_version"
    fi
  done < <(find "$LOCAL_PACKAGE_DIR" -maxdepth 1 \( -type f -o -type l \) \
    -name "$CAMERA_KERNEL_PACKAGE_GLOB" -print0 2>/dev/null | sort -z)

  if [[ -z "$selected_package" ]]; then
    echo "Missing staged camera kernel package in: $LOCAL_PACKAGE_DIR" >&2
    echo "Expected: $CAMERA_KERNEL_PACKAGE_GLOB" >&2
    exit 1
  fi

  printf '%s\n' "$selected_package"
}

ramdisk_path="$PMOS_BOOT_DIR/$PMOS_INITRAMFS"
ramdisk_extra_path="$PMOS_BOOT_DIR/$PMOS_INITRAMFS_EXTRA"

for path in "$ramdisk_path" "$ramdisk_extra_path"; do
  if [[ ! -f "$path" ]]; then
    echo "Missing PMOS boot artifact: $path" >&2
    exit 1
  fi
done

build_selfcontained_ramdisk() {
  local out="$WORK_DIR/initramfs-selfcontained"
  local unpack="$WORK_DIR/initramfs-unpack"
  local init_tmp="$WORK_DIR/init.patched"

  for tool in zstd cpio find sort awk; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "Missing required tool for self-contained ramdisk: $tool" >&2
      exit 1
    fi
  done

  remove_build_path "$unpack"
  remove_build_path "$out"
  remove_build_path "$init_tmp"
  mkdir -p "$unpack"

  (
    cd "$unpack"
    zstd -dc "$ramdisk_path" | cpio -id --quiet
  )

  if [[ ! -f "$unpack/init" ]]; then
    echo "PMOS initramfs did not contain /init." >&2
    exit 1
  fi

  if ! grep -Fq 'extract_initramfs_extra /boot/initramfs-extra' "$unpack/init"; then
    echo "PMOS /init does not contain the expected initramfs-extra extraction block." >&2
    exit 1
  fi

  awk '
    $0 == "wait_boot_partition" {
      print "if [ -e /initramfs-extra ]; then"
      print "\textract_initramfs_extra /initramfs-extra"
      print "else"
      print "\twait_boot_partition"
      next
    }
    $0 == "mount_boot_partition /boot" {
      print "\tmount_boot_partition /boot"
      next
    }
    $0 == "extract_initramfs_extra /boot/initramfs-extra" {
      print "\textract_initramfs_extra /boot/initramfs-extra"
      print "fi"
      next
    }
    { print }
  ' "$unpack/init" > "$init_tmp"
  mv "$init_tmp" "$unpack/init"
  chmod 0755 "$unpack/init"

  cp -a "$ramdisk_extra_path" "$unpack/initramfs-extra"

  (
    cd "$unpack"
    find . -print0 | sort -z | cpio --null -o -H newc --quiet | zstd -19 -T0 > "$out"
  )

  ramdisk_path="$out"
}

if [[ "${PMOS_EMBED_INITRAMFS_EXTRA:-1}" == "1" ]]; then
  build_selfcontained_ramdisk
fi

kernel_path="$PMOS_BOOT_DIR/$PMOS_KERNEL"
dtb_path="$PMOS_BOOT_DIR/$PMOS_DTB"

case "${BOOT_KERNEL_SOURCE:-pmos-snapshot}" in
  pmos-snapshot)
    for path in "$kernel_path" "$dtb_path"; do
      if [[ ! -f "$path" ]]; then
        echo "Missing PMOS boot artifact: $path" >&2
        exit 1
      fi
    done
    ;;
  camera-package)
    if ! command -v bsdtar >/dev/null 2>&1; then
      echo "Missing required tool for camera kernel packages: bsdtar" >&2
      exit 1
    fi

    camera_package="$(select_newest_camera_package)"
    camera_package_info="$(pacman -Qp "$camera_package")"
    echo "Selected camera kernel package: $camera_package_info"
    echo "  $camera_package"

    kernel_path="$WORK_DIR/vmlinuz-oneplus6t-camera"
    dtb_path="$WORK_DIR/sdm845-oneplus-fajita-camera.dtb"
    bsdtar -xOf "$camera_package" boot/vmlinuz-oneplus6t-camera > "$kernel_path"
    bsdtar -xOf "$camera_package" boot/dtbs/qcom/sdm845-oneplus-fajita.dtb > "$dtb_path"
    ;;
  *)
    echo "Unsupported BOOT_KERNEL_SOURCE: $BOOT_KERNEL_SOURCE" >&2
    exit 1
    ;;
esac

kernel_dtb="$WORK_DIR/kernel-dtb"
boot_img="$OUT_DIR/oneplus6t-arch-boot.img"

cat "$kernel_path" "$dtb_path" > "$kernel_dtb"

mkbootimg \
  --kernel "$kernel_dtb" \
  --ramdisk "$ramdisk_path" \
  --cmdline "$BOOT_CMDLINE" \
  --base "$BOOT_BASE" \
  --kernel_offset "$BOOT_KERNEL_OFFSET" \
  --ramdisk_offset "$BOOT_RAMDISK_OFFSET" \
  --second_offset "$BOOT_SECOND_OFFSET" \
  --tags_offset "$BOOT_TAGS_OFFSET" \
  --pagesize "$BOOT_PAGESIZE" \
  --header_version "$BOOT_HEADER_VERSION" \
  -o "$boot_img"

sha256sum "$boot_img" > "$boot_img.sha256"

echo "Built boot image:"
echo "$boot_img"
echo "Kernel source: ${BOOT_KERNEL_SOURCE:-pmos-snapshot}"
if [[ "${PMOS_EMBED_INITRAMFS_EXTRA:-1}" == "1" ]]; then
  echo "Ramdisk: self-contained with embedded initramfs-extra"
else
  echo "Ramdisk: PMOS initramfs without embedded initramfs-extra"
fi
cat "$boot_img.sha256"
