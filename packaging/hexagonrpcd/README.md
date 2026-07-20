# hexagonrpcd Arch Package

This is the local Arch package recipe for the Qualcomm Hexagon FastRPC daemon
used by the OnePlus 6/6T sensor stack.

Upstream:

```text
https://github.com/linux-msm/hexagonrpc
```

PMOS/Alpine reference:

```text
https://gitlab.alpinelinux.org/alpine/aports/-/raw/master/community/hexagonrpcd/APKBUILD
```

The OnePlus 6T release needs this package plus the
`firmware-oneplus-sdm845-sensors` payload before accelerometer, proximity,
ambient light, and magnetometer support can be marked working on Arch.

This package deliberately only owns the daemon binary, shared library, helper
binary, and man page. The OnePlus 6T profile overlay owns the `fastrpc` user,
udev rules, and systemd units because those files are device-specific.

Build it on aarch64 and stage it for image injection:

```text
scripts/build-hexagonrpcd-package.sh oneplus-fajita
```

If the package was built elsewhere, stage it without copying package data:

```text
scripts/stage-local-package.sh oneplus-fajita /path/to/hexagonrpcd-0.4.0-2-aarch64.pkg.tar.xz
```

The live OnePlus 6T Arch prototype built `hexagonrpcd 0.4.0-2` successfully on
2026-07-03. Installing it makes `hexagonrpcd-sdsp.service` active.

The first Arch blocker was a missing sensor registry/config payload:

```text
/mnt/vendor/persist/sensors/registry/registry
/usr/share/qcom/sdm845/OnePlus/oneplus6/sensors
```

After adding `firmware-oneplus-sdm845-sensors`, a manual late `run-sdsp` lab
still left SensorProxy waiting for the SSC `registry` sensor. The lab log also
showed SDSP write-open attempts under `/mnt/vendor/persist/sensors/registry`,
but Alpine/PMOS packages upstream `hexagonrpcd 0.4.0` without a write-support
patch. Treat those lines as expected calibration persistence noise until proven
otherwise.

The local PMOS reference starts `hexagonrpcd-sdsp` in OpenRC `sysinit` and
delays `iio-sensor-proxy` by 10 seconds. The OnePlus 6T systemd overlay now
mirrors that timing for `ENABLE_HEXAGON_SENSORS=1` lab images.

Live result on 2026-07-04: that early-start timing booted to Hyprland without
crashdump and `ssccli` returned live accelerometer, gyroscope, ambient light,
proximity, magnetometer, and compass readings. Remaining work is above this
package: `iio-sensor-proxy` currently exposes ambient light only over D-Bus, so
auto-rotate needs a SensorProxy/libssc fix or a direct SSC orientation helper.
