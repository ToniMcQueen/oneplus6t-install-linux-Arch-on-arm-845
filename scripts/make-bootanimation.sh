#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  cat >&2 <<'EOF'
Usage:
  scripts/make-bootanimation.sh /path/to/source-video.mp4 [output.zip]

Creates an Android-style bootanimation.zip from video frames only.
Audio is ignored and never copied into the output.
EOF
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_video="$1"
output_zip="${2:-$ROOT_DIR/profiles/oneplus-fajita/overlay/usr/share/oneplus6t/bootanimation.zip}"
case "$output_zip" in
  /*) ;;
  *) output_zip="$ROOT_DIR/$output_zip" ;;
esac
work_dir="$ROOT_DIR/work/bootanimation"
frames_dir="$work_dir/part0"

fps="${BOOTANIMATION_FPS:-8}"
width="${BOOTANIMATION_WIDTH:-360}"
height="${BOOTANIMATION_HEIGHT:-780}"
frame_format="${BOOTANIMATION_FORMAT:-jpg}"
jpeg_quality="${BOOTANIMATION_JPEG_QUALITY:-5}"

for tool in ffmpeg zip; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool: $tool" >&2
    exit 1
  fi
done

if [[ ! -f "$source_video" ]]; then
  echo "Source video does not exist: $source_video" >&2
  exit 1
fi

rm -rf "$work_dir"
mkdir -p "$frames_dir" "$(dirname "$output_zip")"

case "$frame_format" in
  png)
    frame_pattern="$frames_dir/%05d.png"
    extra_ffmpeg_args=()
    ;;
  jpg|jpeg)
    frame_format=jpg
    frame_pattern="$frames_dir/%05d.jpg"
    extra_ffmpeg_args=(-q:v "$jpeg_quality")
    ;;
  *)
    echo "Unsupported BOOTANIMATION_FORMAT=$frame_format; use png or jpg." >&2
    exit 1
    ;;
esac

cat > "$work_dir/desc.txt" <<EOF
$width $height $fps
p 0 0 part0
EOF

ffmpeg -hide_banner -loglevel error -y \
  -i "$source_video" \
  -map 0:v:0 -an \
  -vf "fps=${fps},scale=${width}:${height}:force_original_aspect_ratio=decrease,pad=${width}:${height}:(ow-iw)/2:(oh-ih)/2:black" \
  "${extra_ffmpeg_args[@]}" \
  "$frame_pattern"

(
  cd "$work_dir"
  rm -f "$output_zip"
  zip -0 -q -r "$output_zip" desc.txt part0
)

echo "Built no-audio Android-style boot animation:"
echo "  $output_zip"
du -h "$output_zip"
