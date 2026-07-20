#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Replace or build the OnePlus 6T intro boot video.

Usage:
  scripts/replace-boot-video.sh /path/to/video.mp4
  scripts/replace-boot-video.sh /path/to/video.mp4 /path/to/output/bootanimation.zip

Default output:
  profiles/oneplus-fajita/overlay/usr/share/oneplus6t/bootanimation.zip

Accepted video length:
  default: 2s to 45s

The boot service currently displays the animation for up to 45 seconds. Longer
videos would be cut off during boot, so this script refuses them unless you
intentionally override the limit.

Environment overrides:
  BOOTANIMATION_MIN_SECONDS=2
  BOOTANIMATION_MAX_SECONDS=45
  BOOTANIMATION_FPS=8
  BOOTANIMATION_WIDTH=360
  BOOTANIMATION_HEIGHT=780
  BOOTANIMATION_FORMAT=jpg
  BOOTANIMATION_JPEG_QUALITY=5
  BOOTANIMATION_FORCE=1       allow videos outside the duration window

Audio is ignored and never copied into bootanimation.zip.
EOF
}

die() {
  printf 'replace-boot-video: %s\n' "$*" >&2
  exit 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

[[ $# -ge 1 && $# -le 2 ]] || {
  usage >&2
  exit 2
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_video="$1"
output_zip="${2:-$ROOT_DIR/profiles/oneplus-fajita/overlay/usr/share/oneplus6t/bootanimation.zip}"
make_bootanimation="$ROOT_DIR/scripts/make-bootanimation.sh"

min_seconds="${BOOTANIMATION_MIN_SECONDS:-2}"
max_seconds="${BOOTANIMATION_MAX_SECONDS:-45}"
force="${BOOTANIMATION_FORCE:-0}"

[[ -f "$source_video" ]] || die "source video does not exist: $source_video"
[[ -x "$make_bootanimation" ]] || die "missing executable: scripts/make-bootanimation.sh"

for tool in ffprobe ffmpeg zip unzip awk date cp grep; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done

duration="$(
  ffprobe -v error \
    -select_streams v:0 \
    -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 \
    "$source_video"
)"

[[ -n "$duration" && "$duration" != "N/A" ]] || die "could not read video duration"

duration_ok="$(
  awk -v duration="$duration" -v min="$min_seconds" -v max="$max_seconds" '
    BEGIN {
      if (duration >= min && duration <= max) print "yes";
      else print "no";
    }
  '
)"

printf 'Source video: %s\n' "$source_video"
printf 'Duration:     %.2f seconds\n' "$duration"
printf 'Allowed:      %ss to %ss\n' "$min_seconds" "$max_seconds"
printf 'Output zip:   %s\n' "$output_zip"

if [[ "$duration_ok" != "yes" && "$force" != "1" ]]; then
  cat >&2 <<EOF

This video is outside the supported boot intro window.

Pick a video between ${min_seconds}s and ${max_seconds}s, or deliberately override:
  BOOTANIMATION_FORCE=1 scripts/replace-boot-video.sh "$source_video" "$output_zip"
EOF
  exit 1
fi

if [[ -f "$output_zip" ]]; then
  backup="$output_zip.backup-$(date -u +%Y%m%dT%H%M%SZ)"
  cp -p "$output_zip" "$backup"
  printf 'Backup:       %s\n' "$backup"
fi

"$make_bootanimation" "$source_video" "$output_zip"

desc="$(unzip -p "$output_zip" desc.txt 2>/dev/null || true)"
if ! printf '%s\n' "$desc" | grep -Eq '^[0-9]+ [0-9]+ [0-9]+$'; then
  die "new bootanimation.zip is missing a valid Android-style desc.txt"
fi

if unzip -l "$output_zip" | grep -Eiq '\.(mp3|wav|ogg|aac|m4a|mp4|mov)$|audio'; then
  die "new bootanimation.zip unexpectedly contains audio or video payloads"
fi

printf '\nReplacement complete.\n'
printf 'The next image build will include:\n'
printf '  %s\n' "${output_zip#"$ROOT_DIR/"}"
