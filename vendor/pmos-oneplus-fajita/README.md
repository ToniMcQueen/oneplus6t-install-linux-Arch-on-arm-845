# PMOS OnePlus 6T Boot Artifacts

Place the PMOS fajita boot artifacts in:

```text
vendor/pmos-oneplus-fajita/boot/
```

Expected filenames:

```text
vmlinuz
initramfs
initramfs-extra
sdm845-oneplus-fajita.dtb
linux.efi
boot.img
```

These are not committed to git. They are generated or extracted from the known
working postmarketOS OnePlus 6T image.

For low-space local builds, make `boot` a symlink instead of copying the files.
Example:

```text
vendor/pmos-oneplus-fajita/boot -> /path/to/extracted/pmos/boot
```
