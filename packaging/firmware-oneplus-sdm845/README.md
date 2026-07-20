# firmware-oneplus-sdm845 Arch Package

This package mirrors the postmarketOS `firmware-oneplus-sdm845` base package
for the OnePlus 6/6T family.

It installs the base OnePlus firmware selected by PMOS `firmware.files`,
including:

```text
/usr/lib/firmware/qcom/sdm845/oneplus6/slpi.mbn
/usr/lib/firmware/qcom/sdm845/oneplus6/adsp.mbn
/usr/lib/firmware/qcom/sdm845/oneplus6/cdsp.mbn
/usr/lib/firmware/qcom/sdm845/oneplus6/mba.mbn
/usr/lib/firmware/qcom/sdm845/oneplus6/modem.mbn
/usr/lib/firmware/qcom/sdm845/oneplus6/*.jsn
/usr/lib/firmware/postmarketos/
/usr/lib/firmware/qca/oneplus6/
```

PMOS lists these paths under `/lib/firmware`. The Arch package installs them
under `/usr/lib/firmware`, matching Arch's `/lib -> /usr/lib` filesystem
layout.

Build and stage it from the repo root:

```sh
scripts/build-oneplus-firmware-package.sh oneplus-fajita
```

The files are proprietary firmware. The repo keeps only this PKGBUILD and
PMOS-derived checksums; it does not commit the payload itself.
