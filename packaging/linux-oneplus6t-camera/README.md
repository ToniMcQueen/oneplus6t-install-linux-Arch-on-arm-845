# OnePlus 6T Camera Kernel Package

This package pins the SDM845 camera development branch at:

```text
26f9dfad4030de634dbf50f398f95281c29c3965
```

The branch contains Qualcomm CAMSS C-PHY support, drivers for the OnePlus
`imx371`, `imx376`, and `imx519` sensors, and the matching OnePlus device-tree
camera graph. `camera-series.tsv` records the individual commits and original
authors so patches can be removed as equivalent work reaches upstream Linux.

The package starts from the pinned postmarketOS SDM845 configuration and merges
the camera options in `camera.config` plus the S4 lab option in
`hibernate.config`. It installs a gzip kernel, the `fajita` DTB, matching
modules, source provenance, and the effective camera/power configuration.

The package carries two local corrective patches for the main rear camera path.
The first fixes the branch's CSID C-PHY selector expression, which converted the
bit-24 mask to a boolean before writing the register. The second bounds SDM845
C-PHY lane-table programming to the three register sets that actually exist for
the 3-phase table. Without that, the C-PHY path walks past the table entries
used by `imx519`.

The package also carries temporary lab diagnostics for `imx519`, including
logging and disabled-by-default C-PHY override parameters. These are there to
test lane assignment, CSIPHY lane-control, settle timing, and CSID receive
programming without rebuilding for every variant.

These fixes and diagnostics are necessary for `imx519`, but physical raw
streaming still has to be proven before the main camera can be marked working.

This is a candidate kernel, not the recovery kernel. Keep the known-good PMOS
6.9 snapshot available until a paired camera/S4 boot/root image passes the full
phone parity report.

The hibernation option is intentionally minimal:

```text
CONFIG_HIBERNATION=y
```

The pinned PMOS base config already has `CONFIG_ARCH_HIBERNATION_POSSIBLE=y`
and `CONFIG_SWAP=y`, but hibernation itself is disabled. Enabling this should
make `/sys/power/state` expose `disk` if the kernel accepts the dependency set.
Swapfile and `resume=` plumbing are deliberately separate later steps.
