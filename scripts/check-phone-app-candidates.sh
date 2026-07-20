#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${1:-oneplus-fajita}"
PROFILE_DIR="$ROOT_DIR/profiles/$PROFILE"

usage() {
  cat <<EOF
Usage: scripts/check-phone-app-candidates.sh [profile]

Checks research-only phone/SMS app candidate packages against Arch Linux ARM
aarch64 repository sync databases without installing them or requiring root.

Input:
  profiles/<profile>/phone-app-candidates.txt

Output:
  out/<profile>/phone-app-candidate-package-report.md
EOF
}

if [[ "${1:-}" == "--help" || "${2:-}" == "--help" ]]; then
  usage
  exit 0
elif [[ $# -gt 1 ]]; then
  usage >&2
  exit 1
fi

if [[ ! -d "$PROFILE_DIR" ]]; then
  echo "Missing profile directory: $PROFILE_DIR" >&2
  exit 1
fi

CANDIDATES_FILE="${CANDIDATES_FILE:-$PROFILE_DIR/phone-app-candidates.txt}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/out/$PROFILE}"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/work/$PROFILE/phone-app-package-check}"
DB_CACHE_DIR="${DB_CACHE_DIR:-$ROOT_DIR/cache/alarm-syncdb/aarch64}"
REPORT="$OUT_DIR/phone-app-candidate-package-report.md"
MIRROR_BASE="${MIRROR_BASE:-http://mirror.archlinuxarm.org/aarch64}"
REPOS=(core extra alarm aur)
INDEX_DIR="$(mktemp -d "$WORK_DIR/index.XXXXXX")"
INDEX_TSV="$WORK_DIR/package-index.tsv"

if [[ ! -f "$CANDIDATES_FILE" ]]; then
  echo "Missing candidate manifest: $CANDIDATES_FILE" >&2
  exit 1
fi

for tool in curl tar awk sed sort wc date; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool: $tool" >&2
    exit 1
  fi
done

mapfile -t CANDIDATES < <(awk '
  /^[[:space:]]*($|#)/ { next }
  { print $1 }
' "$CANDIDATES_FILE")

if [[ "${#CANDIDATES[@]}" -eq 0 ]]; then
  echo "No package candidates listed in: $CANDIDATES_FILE" >&2
  exit 1
fi

mkdir -p "$OUT_DIR" "$WORK_DIR" "$DB_CACHE_DIR"

download_syncdb() {
  local repo="$1"
  local db="$DB_CACHE_DIR/$repo.db"
  local tmp="$db.tmp"

  curl -fsSL "$MIRROR_BASE/$repo/$repo.db" -o "$tmp"
  mv "$tmp" "$db"
}

field_from_desc() {
  local field="$1"
  awk -v field="%$field%" '
    $0 == field { getline; print; exit }
  '
}

for repo in "${REPOS[@]}"; do
  download_syncdb "$repo"
done

: > "$INDEX_TSV"

for repo in "${REPOS[@]}"; do
  db="$DB_CACHE_DIR/$repo.db"
  repo_dir="$INDEX_DIR/$repo"
  mkdir -p "$repo_dir"
  tar -xf "$db" -C "$repo_dir"

  while IFS= read -r desc_file; do
    name="$(field_from_desc NAME < "$desc_file")"
    version="$(field_from_desc VERSION < "$desc_file")"
    size_bytes="$(field_from_desc ISIZE < "$desc_file")"
    desc="$(field_from_desc DESC < "$desc_file" | tr '\t' ' ')"
    [[ -n "$name" ]] || continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$repo" "$version" "$size_bytes" "$desc" >> "$INDEX_TSV"
  done < <(find "$repo_dir" -type f -name desc | sort)
done

tmp_table="$WORK_DIR/table.md"
tmp_available="$WORK_DIR/available.txt"
tmp_missing="$WORK_DIR/missing.txt"
tmp_descriptions="$WORK_DIR/descriptions.txt"
: > "$tmp_table"
: > "$tmp_available"
: > "$tmp_missing"
: > "$tmp_descriptions"

for pkg in "${CANDIDATES[@]}"; do
  info="$(awk -F '\t' -v pkg="$pkg" '$1 == pkg { print; exit }' "$INDEX_TSV")"
  if [[ -z "$info" ]]; then
    printf '| `%s` | missing |  |  |  |\n' "$pkg" >> "$tmp_table"
    printf '%s\n' "$pkg" >> "$tmp_missing"
    continue
  fi

  IFS=$'\t' read -r name repo version size_bytes desc <<< "$info"
  desc="$(sed 's/|/\\|/g' <<<"$desc")"
  size="${size_bytes:-unknown}"
  if [[ "$size" =~ ^[0-9]+$ ]]; then
    size="$(awk -v bytes="$size" 'BEGIN { printf "%.1f MiB", bytes / 1024 / 1024 }')"
  fi

  printf '| `%s` | available | `%s` | `%s` | %s |\n' "$name" "$repo" "$version" "${size:-unknown}" >> "$tmp_table"
  printf '%s\n' "$name" >> "$tmp_available"
  printf '%s: %s\n' "$name" "$desc" >> "$tmp_descriptions"
done

{
  echo "# Phone App Candidate Package Report"
  echo
  echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "Profile: \`$PROFILE\`"
  echo
  echo "Candidate manifest:"
  echo
  echo "\`\`\`text"
  echo "$CANDIDATES_FILE"
  echo "\`\`\`"
  echo
  echo "This is a research report only. It does not install packages and does not"
  echo "change \`profiles/$PROFILE/packages.txt\`."
  echo
  echo "Source mirror:"
  echo
  echo "\`\`\`text"
  echo "$MIRROR_BASE"
  echo "\`\`\`"
  echo
  echo "## Summary"
  echo
  echo "\`\`\`text"
  echo "available: $(wc -l < "$tmp_available")"
  echo "missing:   $(wc -l < "$tmp_missing")"
  echo "\`\`\`"
  echo
  echo "## Results"
  echo
  echo "| Package | Status | Repo | Version | Installed size |"
  echo "| --- | --- | --- | --- | --- |"
  cat "$tmp_table"
  echo
  if [[ -s "$tmp_missing" ]]; then
    echo "## Missing Candidates"
    echo
    sed 's/^/- `/' "$tmp_missing" | sed 's/$/`/'
    echo
  fi
  if [[ -s "$tmp_descriptions" ]]; then
    echo "## Available Package Descriptions"
    echo
    sort -u "$tmp_descriptions" | sed 's/^/- /'
    echo
  fi
  echo "## Decision Rule"
  echo
  echo "Do not add any existing mobile app candidate to the golden image until its"
  echo "runtime dependencies, shell assumptions, storage paths, and ModemManager or"
  echo "oFono integration are reviewed on the live OnePlus 6T image."
} > "$REPORT"

echo "Wrote phone app package candidate report:"
echo "$REPORT"
