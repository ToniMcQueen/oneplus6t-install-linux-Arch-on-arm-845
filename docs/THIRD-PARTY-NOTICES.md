# Third-Party Notices

This project carries small device-specific configuration files from upstream
projects where needed for reproducible OnePlus 6T builds.

## SDM845 OnePlus camera kernel

Package metadata and patch provenance:

```text
packaging/linux-oneplus6t-camera/
```

Source:

```text
https://gitlab.com/sdm845-mainline/linux
commit 26f9dfad4030de634dbf50f398f95281c29c3965
```

The source archive is downloaded during package builds and is not committed to
this repository. The kernel and carried camera drivers are licensed under
GPL-2.0-only. Original commit authors and subjects are preserved in
`camera-series.tsv`.

## ALSA UCM: OnePlus 6T fajita

Files:

```text
profiles/oneplus-fajita/overlay/usr/share/alsa/ucm2/OnePlus/fajita/fajita.conf
profiles/oneplus-fajita/overlay/usr/share/alsa/ucm2/OnePlus/fajita/HiFi.conf
profiles/oneplus-fajita/overlay/usr/share/alsa/ucm2/OnePlus/fajita/VoiceCall.conf
profiles/oneplus-fajita/overlay/usr/share/alsa/ucm2/conf.d/sdm845/OnePlus 6T.conf
profiles/oneplus-fajita/overlay/usr/share/alsa/ucm2/conf.d/sdm845/oneplus-OnePlus6T-.conf
```

Source:

```text
sdm845-mainline/alsa-ucm-conf
postmarketOS package: alsa-ucm-conf-sdm845
```

License:

```text
BSD 3-Clause License

Copyright (c) 2019, Advanced Linux Sound Architecture (ALSA) project
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```
