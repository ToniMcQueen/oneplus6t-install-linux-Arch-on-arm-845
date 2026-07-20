# firmware-oneplus-sdm845-sensors Arch Package

This package mirrors the postmarketOS `firmware-oneplus-sdm845-sensors`
subpackage for the OnePlus 6/6T family.

It installs the sensor-side Qualcomm payload from
`firmware-oneplus-sdm845`:

```text
/usr/share/qcom/sdm845/OnePlus/oneplus6/dsp/sdsp
/usr/share/qcom/sdm845/OnePlus/oneplus6/sensors
/usr/share/qcom/sdm845/OnePlus/enchilada -> oneplus6
/usr/share/qcom/sdm845/OnePlus/fajita -> oneplus6
```

The files are proprietary firmware/registry data. The repo keeps only this
PKGBUILD and PMOS-derived checksums; it does not commit the payload itself.

Build and stage it from the repo root:

```sh
scripts/build-oneplus-sensors-package.sh oneplus-fajita
```

The rootfs builder will inject the staged package from:

```text
out/oneplus-fajita/packages/
```

Live prototype result on 2026-07-04: installing this payload fixed the old
`hexagonrpcd` file-not-found error for
`/mnt/vendor/persist/sensors/registry/registry`. `hexagonrpcd-sdsp.service`
remained active and served `/dev/fastrpc-sdsp`, but `iio-sensor-proxy` still
reported the SSC `registry` sensor unavailable until the SDSP boot path is
debugged further.
