#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="oneplus-fajita"
ASSET_NAME="${RELEASE_INPUTS_ASSET:-oneplus6t-release-inputs.tar.zst}"
RELEASE_REPO="${RELEASE_REPO:-}"
RELEASE_TAG="${RELEASE_TAG:-latest}"
RELEASE_URL="${RELEASE_INPUTS_URL:-}"
BUNDLE_PATH=""
EXPECTED_SHA256="${RELEASE_INPUTS_SHA256:-}"
FORCE=0
INSTALL_DEPS="${ONEPLUS6T_INSTALL_DEPS:-0}"
DOWNLOAD_ATTEMPTS="${RELEASE_INPUTS_DOWNLOAD_ATTEMPTS:-0}"
DOWNLOAD_RETRY_DELAY="${RELEASE_INPUTS_DOWNLOAD_RETRY_DELAY:-20}"
DOWNLOAD_WARN_AFTER="${RELEASE_INPUTS_DOWNLOAD_WARN_AFTER:-5}"
GITHUB_AUTH_ATTEMPTS="${RELEASE_INPUTS_GITHUB_AUTH_ATTEMPTS:-0}"
RELEASE_INPUTS_TMP=""

cleanup() {
  if [[ -n "$RELEASE_INPUTS_TMP" ]]; then
    rm -rf "$RELEASE_INPUTS_TMP"
  fi
}

usage() {
  cat <<'EOF'
Usage: scripts/fetch-release-inputs.sh [options]

Download or import the binary input bundle needed by the OnePlus 6T installer.

The source repo is intentionally kept small and clean. This script fills in the
large release inputs that are not committed to git:

  vendor/pmos-oneplus-fajita/boot/{vmlinuz,initramfs,initramfs-extra,sdm845-oneplus-fajita.dtb}
  out/oneplus-fajita/packages/hexagonrpcd-*-aarch64.pkg.tar.*
  out/oneplus-fajita/packages/firmware-oneplus-sdm845-*-any.pkg.tar.*
  out/oneplus-fajita/packages/firmware-oneplus-sdm845-sensors-*-any.pkg.tar.*
  vendor/pmos-compat-payload/                              optional
  vendor/pmos-reference/*.tar.zst                          optional

Options:
  --profile NAME       Device profile, default: oneplus-fajita
  --repo OWNER/REPO    GitHub repo for release assets. Default: origin remote
  --tag TAG            Release tag, default: latest
  --asset NAME         Release asset name, default: oneplus6t-release-inputs.tar.zst
  --url URL            Download bundle from an explicit URL
  --bundle PATH        Use a local bundle instead of downloading
  --sha256 HASH        Expected SHA-256 of the bundle
  --install-deps       Install missing host tools with pacman, paru, or yay
  --force             Download/import even if all inputs are already present
  -h, --help          Show this help

Accepted bundle layouts:
  1. Repository-shaped:
       vendor/pmos-oneplus-fajita/boot/...
       out/oneplus-fajita/packages/...
  2. Simple:
       pmos-boot/...
       packages/...

If the bundle contains sha256sums.txt, SHA256SUMS, or SHA256SUMS.txt, the file
checksums are verified after extraction.
EOF
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --profile)
      PROFILE="${2:?missing value for --profile}"
      shift 2
      ;;
    --repo)
      RELEASE_REPO="${2:?missing value for --repo}"
      shift 2
      ;;
    --tag)
      RELEASE_TAG="${2:?missing value for --tag}"
      shift 2
      ;;
    --asset)
      ASSET_NAME="${2:?missing value for --asset}"
      shift 2
      ;;
    --url)
      RELEASE_URL="${2:?missing value for --url}"
      shift 2
      ;;
    --bundle)
      BUNDLE_PATH="${2:?missing value for --bundle}"
      shift 2
      ;;
    --sha256)
      EXPECTED_SHA256="${2:?missing value for --sha256}"
      shift 2
      ;;
    --install-deps)
      INSTALL_DEPS=1
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

PROFILE_DIR="$ROOT_DIR/profiles/$PROFILE"
if [[ ! -f "$PROFILE_DIR/config.env" ]]; then
  echo "Unknown profile or missing config: $PROFILE_DIR/config.env" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$PROFILE_DIR/config.env"

OUT_DIR="${OUT_DIR:-$ROOT_DIR/out/$PROFILE}"
LOCAL_PACKAGE_DIR="${LOCAL_PACKAGE_DIR:-$OUT_DIR/packages}"
PMOS_BOOT_DIR="${PMOS_BOOT_DIR:-$ROOT_DIR/vendor/pmos-oneplus-fajita/boot}"
CACHE_DIR="${CACHE_DIR:-$ROOT_DIR/cache}"
DOWNLOAD_DIR="$CACHE_DIR/release-inputs"

required_boot_files=(
  "$PMOS_BOOT_DIR/$PMOS_KERNEL"
  "$PMOS_BOOT_DIR/$PMOS_INITRAMFS"
  "$PMOS_BOOT_DIR/$PMOS_INITRAMFS_EXTRA"
  "$PMOS_BOOT_DIR/$PMOS_DTB"
)

optional_payload_ready() {
  [[ -d "$PMOS_COMPAT_PAYLOAD_DIR" ]] || return 1
  [[ -f "$PMOS_HARDWARE_REFERENCE_TARBALL" ]] || return 1
}

have_glob() {
  compgen -G "$1" >/dev/null
}

inputs_ready() {
  local path

  for path in "${required_boot_files[@]}"; do
    [[ -f "$path" ]] || return 1
  done

  have_glob "$LOCAL_PACKAGE_DIR/hexagonrpcd-*-aarch64.pkg.tar.*" || return 1
  have_glob "$LOCAL_PACKAGE_DIR/firmware-oneplus-sdm845-[0-9]*-any.pkg.tar.*" || return 1
  have_glob "$LOCAL_PACKAGE_DIR/firmware-oneplus-sdm845-sensors-*-any.pkg.tar.*" || return 1

  return 0
}

print_missing_inputs() {
  local path

  echo "Required release inputs:"
  for path in "${required_boot_files[@]}"; do
    if [[ -f "$path" ]]; then
      echo "  OK      ${path#"$ROOT_DIR/"}"
    else
      echo "  MISSING ${path#"$ROOT_DIR/"}"
    fi
  done

  if have_glob "$LOCAL_PACKAGE_DIR/hexagonrpcd-*-aarch64.pkg.tar.*"; then
    echo "  OK      ${LOCAL_PACKAGE_DIR#"$ROOT_DIR/"}/hexagonrpcd-*-aarch64.pkg.tar.*"
  else
    echo "  MISSING ${LOCAL_PACKAGE_DIR#"$ROOT_DIR/"}/hexagonrpcd-*-aarch64.pkg.tar.*"
  fi

  if have_glob "$LOCAL_PACKAGE_DIR/firmware-oneplus-sdm845-[0-9]*-any.pkg.tar.*"; then
    echo "  OK      ${LOCAL_PACKAGE_DIR#"$ROOT_DIR/"}/firmware-oneplus-sdm845-[0-9]*-any.pkg.tar.*"
  else
    echo "  MISSING ${LOCAL_PACKAGE_DIR#"$ROOT_DIR/"}/firmware-oneplus-sdm845-[0-9]*-any.pkg.tar.*"
  fi

  if have_glob "$LOCAL_PACKAGE_DIR/firmware-oneplus-sdm845-sensors-*-any.pkg.tar.*"; then
    echo "  OK      ${LOCAL_PACKAGE_DIR#"$ROOT_DIR/"}/firmware-oneplus-sdm845-sensors-*-any.pkg.tar.*"
  else
    echo "  MISSING ${LOCAL_PACKAGE_DIR#"$ROOT_DIR/"}/firmware-oneplus-sdm845-sensors-*-any.pkg.tar.*"
  fi

  if [[ -d "$PMOS_COMPAT_PAYLOAD_DIR" ]]; then
    echo "  OK      ${PMOS_COMPAT_PAYLOAD_DIR#"$ROOT_DIR/"}"
  else
    echo "  OPTIONAL-MISSING ${PMOS_COMPAT_PAYLOAD_DIR#"$ROOT_DIR/"}"
  fi

  if [[ -f "$PMOS_HARDWARE_REFERENCE_TARBALL" ]]; then
    echo "  OK      ${PMOS_HARDWARE_REFERENCE_TARBALL#"$ROOT_DIR/"}"
  else
    echo "  OPTIONAL-MISSING ${PMOS_HARDWARE_REFERENCE_TARBALL#"$ROOT_DIR/"}"
  fi
}

github_repo_from_origin() {
  local remote url path

  remote="$(git -C "$ROOT_DIR" remote get-url origin 2>/dev/null || true)"
  [[ -n "$remote" ]] || return 1

  case "$remote" in
    https://github.com/*)
      path="${remote#https://github.com/}"
      path="${path%.git}"
      ;;
    git@github.com:*)
      path="${remote#git@github.com:}"
      path="${path%.git}"
      ;;
    ssh://git@github.com/*)
      path="${remote#ssh://git@github.com/}"
      path="${path%.git}"
      ;;
    *)
      return 1
      ;;
  esac

  case "$path" in
    */*) printf '%s\n' "$path" ;;
    *) return 1 ;;
  esac
}

resolve_release_repo() {
  local repo="$RELEASE_REPO"

  if [[ -z "$repo" ]]; then
    repo="$(github_repo_from_origin || true)"
  fi
  if [[ -z "$repo" ]]; then
    repo="ToniMcQueen/oneplus6t-install-linux-Arch-on-arm-845"
  fi

  printf '%s\n' "$repo"
}

release_bundle_url() {
  local repo

  if [[ -n "$RELEASE_URL" ]]; then
    printf '%s\n' "$RELEASE_URL"
    return
  fi

  repo="$(resolve_release_repo)"

  if [[ "$RELEASE_TAG" == "latest" ]]; then
    printf 'https://github.com/%s/releases/latest/download/%s\n' "$repo" "$ASSET_NAME"
  else
    printf 'https://github.com/%s/releases/download/%s/%s\n' "$repo" "$RELEASE_TAG" "$ASSET_NAME"
  fi
}

is_transient_download_error() {
  local log_file="$1"

  [[ -f "$log_file" ]] || return 1
  grep -Eiq \
    'HTTP 5[0-9][0-9]|50[0-9][[:space:]]+Service|Service Unavailable|temporar|timed? ?out|timeout|Failed to connect|Connection (reset|refused)|Could not resolve|network|TLS|SSL|EOF|gateway|upstream|try again' \
    "$log_file"
}

is_github_auth_or_visibility_error() {
  local log_file="$1"

  [[ -f "$log_file" ]] || return 1
  grep -Eiq \
    'not logged into any GitHub hosts|To get started with GitHub CLI|gh auth login|authentication required|Authentication failed|Bad credentials|token.*invalid|HTTP 40[134]|403|release not found|Could not resolve to a Repository|Resource not accessible|Not Found' \
    "$log_file"
}

github_cli_auth_ready() {
  gh auth status >/dev/null 2>&1
}

curl_release_bundle() {
  local url="$1"
  local dest="$2"
  local log_file="$3"

  if [[ -t 2 ]]; then
    curl -fL --progress-bar --retry 3 --retry-delay 2 -o "$dest" "$url" 2>&1 \
      | tee "$log_file" >&2
  else
    curl -fL --retry 3 --retry-delay 2 -o "$dest" "$url" >"$log_file" 2>&1
  fi
}

prompt_github_cli_login_then_retry() {
  local repo="$1"
  local attempt="$2"
  local log_file="$3"

  if [[ "$GITHUB_AUTH_ATTEMPTS" != "0" && "$attempt" -gt "$GITHUB_AUTH_ATTEMPTS" ]]; then
    cat >&2 <<EOF

GitHub CLI authentication still cannot access $repo after $attempt attempt(s).
Last failure log:
EOF
    sed -n '1,120p' "$log_file" >&2 || true
    exit 1
  fi

  cat >&2 <<EOF

The release input bundle is private or hidden from plain curl, and GitHub CLI
could not download it yet.

This usually means gh is not logged in, the token is stale, or the GitHub
account does not have access to:
  $repo

The installer will give you another chance instead of quitting.
Complete the browser login, return to this terminal, and let it continue.
Press Ctrl+C if you want to stop.
EOF

  if ! github_cli_auth_ready; then
    gh auth login -h github.com -p https -s repo,read:org -w
  else
    cat >&2 <<EOF

GitHub CLI is logged in, but the release was not visible.
If you just changed repository access, press Enter to retry.
If this keeps looping, run:
  gh auth refresh -h github.com -s repo,read:org
EOF
    read -r _ || true
  fi
}

retry_release_input_download_or_fail() {
  local attempt="$1"
  local reason="$2"
  local log_file="$3"

  if [[ "$DOWNLOAD_ATTEMPTS" != "0" && "$attempt" -ge "$DOWNLOAD_ATTEMPTS" ]]; then
    cat >&2 <<EOF

Release input download failed after $attempt attempt(s).
Last failure looked transient, but RELEASE_INPUTS_DOWNLOAD_ATTEMPTS=$DOWNLOAD_ATTEMPTS was reached.

Last failure log:
EOF
    sed -n '1,120p' "$log_file" >&2 || true
    exit 1
  fi

  cat >&2 <<EOF

Release input download failed on attempt $attempt:
  $reason

This looks like a temporary GitHub/API/network problem.
The installer will keep trying because the build cannot continue without the
release input bundle. Press Ctrl+C if you want to stop.
EOF

  if [[ "$attempt" -ge "$DOWNLOAD_WARN_AFTER" ]]; then
    cat >&2 <<EOF

WARNING: this has failed $attempt times, which is more than normal.
Check GitHub status, your network, and whether this GitHub account can access
the private release. The installer is still retrying.
EOF
  fi

  sleep "$DOWNLOAD_RETRY_DELAY"
}

gh_release_download_asset() {
  local repo="$1"

  if [[ "$RELEASE_TAG" == "latest" ]]; then
    gh release download \
      --repo "$repo" \
      --pattern "$ASSET_NAME" \
      --dir "$DOWNLOAD_DIR" \
      --clobber
  else
    gh release download "$RELEASE_TAG" \
      --repo "$repo" \
      --pattern "$ASSET_NAME" \
      --dir "$DOWNLOAD_DIR" \
      --clobber
  fi
}

need_tool() {
  local tool="$1"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool: $tool" >&2
    exit 1
  fi
}

detect_arch_package_manager() {
  if command -v pacman >/dev/null 2>&1; then
    printf 'pacman\n'
    return
  fi
  if command -v paru >/dev/null 2>&1; then
    printf 'paru\n'
    return
  fi
  if command -v yay >/dev/null 2>&1; then
    printf 'yay\n'
    return
  fi
  return 1
}

root_prefix_for_pacman() {
  if [[ "$EUID" -eq 0 ]]; then
    return
  fi
  if command -v doas >/dev/null 2>&1; then
    printf 'doas '
    return
  fi
  if command -v sudo >/dev/null 2>&1; then
    printf 'sudo '
    return
  fi
}

install_arch_packages() {
  local manager="$1"
  shift

  if [[ "$#" -eq 0 ]]; then
    return
  fi

  case "$manager" in
    pacman)
      local prefix
      prefix="$(root_prefix_for_pacman)"
      if [[ "$EUID" -ne 0 && -z "$prefix" ]]; then
        echo "Missing doas/sudo for pacman install. Install manually:" >&2
        printf '  pacman -S --needed %s\n' "$*" >&2
        exit 1
      fi
      # shellcheck disable=SC2086
      ${prefix}pacman -S --needed --noconfirm "$@"
      ;;
    paru|yay)
      "$manager" -S --needed --noconfirm "$@"
      ;;
    *)
      echo "Unsupported package manager: $manager" >&2
      exit 1
      ;;
  esac
}

ensure_host_tools() {
  local -a missing_tools=()
  local -a missing_packages=()
  local tool manager prefix

  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || missing_tools+=("$tool")
  done

  if [[ "${#missing_tools[@]}" -eq 0 ]]; then
    return
  fi

  if ! manager="$(detect_arch_package_manager)"; then
    echo "Missing required host tools: ${missing_tools[*]}" >&2
    echo "Install them with your distribution package manager, then rerun." >&2
    exit 1
  fi

  for tool in "${missing_tools[@]}"; do
    case "$tool" in
      curl) missing_packages+=("curl") ;;
      tar) missing_packages+=("tar") ;;
      sha256sum) missing_packages+=("coreutils") ;;
      zstd) missing_packages+=("zstd") ;;
      *) missing_packages+=("$tool") ;;
    esac
  done

  if [[ "$INSTALL_DEPS" == "1" ]]; then
    echo "Installing missing host tools with $manager: ${missing_packages[*]}"
    install_arch_packages "$manager" "${missing_packages[@]}"
    return
  fi

  echo "Missing required host tools: ${missing_tools[*]}" >&2
  case "$manager" in
    pacman)
      prefix="$(root_prefix_for_pacman)"
      printf 'Install with:\n  %spacman -S --needed %s\n' "$prefix" "${missing_packages[*]}" >&2
      ;;
    paru|yay)
      printf 'Install with:\n  %s -S --needed %s\n' "$manager" "${missing_packages[*]}" >&2
      ;;
  esac
  echo "Or rerun this script with --install-deps." >&2
  exit 1
}

download_bundle() {
  local url="$1"
  local dest="$2"
  local repo attempt auth_attempt curl_log gh_log reason

  need_tool curl
  mkdir -p "$DOWNLOAD_DIR"
  echo "Downloading release inputs:"
  echo "  $url"
  repo="$(resolve_release_repo)"
  curl_log="$DOWNLOAD_DIR/${ASSET_NAME}.curl.last.log"
  gh_log="$DOWNLOAD_DIR/${ASSET_NAME}.gh.last.log"
  attempt=1
  auth_attempt=1

  while :; do
    rm -f "$dest" "$curl_log" "$gh_log"

    echo "Release input download attempt $attempt."
    echo "Showing a curl progress bar for the release bundle download."
    if curl_release_bundle "$url" "$dest" "$curl_log"; then
      rm -f "$curl_log" "$gh_log"
      break
    fi

    sed -n '1,80p' "$curl_log" >&2 || true

    if [[ -n "$RELEASE_URL" ]] || ! command -v gh >/dev/null 2>&1; then
      if is_transient_download_error "$curl_log"; then
        retry_release_input_download_or_fail "$attempt" "plain HTTPS download failed" "$curl_log"
        attempt=$((attempt + 1))
        continue
      fi

      echo "Download failed and authenticated gh fallback is unavailable." >&2
      exit 1
    fi

    echo "Plain HTTPS download failed; trying authenticated GitHub CLI release download."
    if gh_release_download_asset "$repo" >"$gh_log" 2>&1 && [[ -f "$dest" ]]; then
      sed -n '1,80p' "$gh_log" >&2 || true
      rm -f "$curl_log" "$gh_log"
      break
    fi

    sed -n '1,120p' "$gh_log" >&2 || true

    if is_transient_download_error "$gh_log"; then
      reason="authenticated GitHub CLI release download failed"
      retry_release_input_download_or_fail "$attempt" "$reason" "$gh_log"
      attempt=$((attempt + 1))
      continue
    fi

    if is_github_auth_or_visibility_error "$gh_log"; then
      prompt_github_cli_login_then_retry "$repo" "$auth_attempt" "$gh_log"
      auth_attempt=$((auth_attempt + 1))
      attempt=$((attempt + 1))
      continue
    fi

    if [[ ! -f "$dest" ]]; then
      echo "GitHub CLI download did not create expected asset: $dest" >&2
    fi
    cat >&2 <<EOF

Release input download cannot continue automatically.
This does not look like a transient GitHub 5xx/network error.

Likely causes:
  - the GitHub account is not authenticated with access to $repo
  - the release or asset is missing
  - RELEASE_INPUTS_TAG points at the wrong release
EOF
    exit 1
  done

  if [[ -z "$EXPECTED_SHA256" ]]; then
    local sidecar="$dest.sha256"
    if curl -fsSL --retry 1 -o "$sidecar" "$url.sha256"; then
      EXPECTED_SHA256="$(awk 'NF {print $1; exit}' "$sidecar")"
      echo "Downloaded checksum sidecar: ${sidecar#"$ROOT_DIR/"}"
    elif [[ -z "$RELEASE_URL" && -x "$(command -v gh 2>/dev/null || true)" ]]; then
      repo="$(resolve_release_repo)"
      if [[ "$RELEASE_TAG" == "latest" ]]; then
        gh release download \
          --repo "$repo" \
          --pattern "$ASSET_NAME.sha256" \
          --dir "$DOWNLOAD_DIR" \
          --clobber >/dev/null 2>&1 || true
      else
        gh release download "$RELEASE_TAG" \
          --repo "$repo" \
          --pattern "$ASSET_NAME.sha256" \
          --dir "$DOWNLOAD_DIR" \
          --clobber >/dev/null 2>&1 || true
      fi
      if [[ -f "$sidecar" ]]; then
        EXPECTED_SHA256="$(awk 'NF {print $1; exit}' "$sidecar")"
        echo "Downloaded checksum sidecar with gh: ${sidecar#"$ROOT_DIR/"}"
      else
        echo "No checksum sidecar found at $url.sha256"
        echo "Continuing without bundle SHA-256 verification."
      fi
    else
      rm -f "$sidecar"
      echo "No checksum sidecar found at $url.sha256"
      echo "Continuing without bundle SHA-256 verification."
    fi
  fi
}

verify_bundle_sha256() {
  local bundle="$1"
  local actual

  [[ -n "$EXPECTED_SHA256" ]] || return
  need_tool sha256sum

  actual="$(sha256sum "$bundle" | awk '{print $1}')"
  if [[ "$actual" != "$EXPECTED_SHA256" ]]; then
    cat >&2 <<EOF
Bundle SHA-256 mismatch.
  expected: $EXPECTED_SHA256
  actual:   $actual
  file:     $bundle
EOF
    exit 1
  fi

  echo "Bundle SHA-256 verified: $actual"
}

safe_extract_bundle() {
  local bundle="$1"
  local dest="$2"
  local entry

  need_tool tar
  mkdir -p "$dest"

  while IFS= read -r entry; do
    case "$entry" in
      ""|/*|../*|*/../*|*"/.."|*"/../"*)
        echo "Refusing unsafe tar entry: $entry" >&2
        exit 1
        ;;
    esac
  done < <(tar -tf "$bundle")

  tar -xf "$bundle" -C "$dest"
}

verify_extracted_checksums() {
  local extracted="$1"
  local sums

  for sums in sha256sums.txt SHA256SUMS SHA256SUMS.txt; do
    if [[ -f "$extracted/$sums" ]]; then
      echo "Verifying extracted files with $sums"
      need_tool sha256sum
      (cd "$extracted" && sha256sum -c "$sums")
      return
    fi
  done

  echo "No extracted sha256sums file found; using required-file checks only."
}

copy_file_if_present() {
  local src="$1"
  local dst="$2"

  if [[ -f "$src" ]]; then
    mkdir -p "$(dirname "$dst")"
    cp -fL "$src" "$dst"
    echo "installed: ${dst#"$ROOT_DIR/"}"
  fi
}

copy_boot_artifacts() {
  local extracted="$1"
  local src=""
  local candidate

  for candidate in \
    "$extracted/vendor/pmos-oneplus-fajita/boot" \
    "$extracted/pmos-boot" \
    "$extracted/boot"; do
    if [[ -f "$candidate/$PMOS_KERNEL" && \
          -f "$candidate/$PMOS_INITRAMFS" && \
          -f "$candidate/$PMOS_INITRAMFS_EXTRA" && \
          -f "$candidate/$PMOS_DTB" ]]; then
      src="$candidate"
      break
    fi
  done

  if [[ -z "$src" ]]; then
    echo "No complete PMOS boot artifact directory found in bundle."
    return
  fi

  echo "Installing PMOS boot artifacts from: ${src#"$extracted/"}"
  copy_file_if_present "$src/$PMOS_KERNEL" "$PMOS_BOOT_DIR/$PMOS_KERNEL"
  copy_file_if_present "$src/$PMOS_INITRAMFS" "$PMOS_BOOT_DIR/$PMOS_INITRAMFS"
  copy_file_if_present "$src/$PMOS_INITRAMFS_EXTRA" "$PMOS_BOOT_DIR/$PMOS_INITRAMFS_EXTRA"
  copy_file_if_present "$src/$PMOS_DTB" "$PMOS_BOOT_DIR/$PMOS_DTB"
}

copy_local_packages() {
  local extracted="$1"
  local src=""
  local candidate package copied=0

  for candidate in \
    "$extracted/out/$PROFILE/packages" \
    "$extracted/packages" \
    "$extracted/$PROFILE/packages"; do
    if [[ -d "$candidate" ]]; then
      src="$candidate"
      break
    fi
  done

  if [[ -z "$src" ]]; then
    echo "No local package directory found in bundle."
    return
  fi

  echo "Installing local packages from: ${src#"$extracted/"}"
  mkdir -p "$LOCAL_PACKAGE_DIR"
  while IFS= read -r -d '' package; do
    cp -fL "$package" "$LOCAL_PACKAGE_DIR/$(basename "$package")"
    echo "installed: ${LOCAL_PACKAGE_DIR#"$ROOT_DIR/"}/$(basename "$package")"
    copied=$((copied + 1))
  done < <(find "$src" -maxdepth 1 \( -type f -o -type l \) \
    \( -name '*.pkg.tar' -o -name '*.pkg.tar.gz' -o -name '*.pkg.tar.xz' -o -name '*.pkg.tar.zst' \) \
    -print0 | sort -z)

  if [[ "$copied" -eq 0 ]]; then
    echo "No Arch package artifacts found in: $src"
  fi
}

copy_optional_pmos_payloads() {
  local extracted="$1"
  local compat_src=""
  local hw_src=""
  local candidate

  for candidate in \
    "$extracted/vendor/pmos-compat-payload" \
    "$extracted/pmos-compat-payload"; do
    if [[ -d "$candidate" ]]; then
      compat_src="$candidate"
      break
    fi
  done

  if [[ -n "$compat_src" ]]; then
    echo "Installing optional PMOS compatibility payload from: ${compat_src#"$extracted/"}"
    rm -rf "$PMOS_COMPAT_PAYLOAD_DIR"
    mkdir -p "$PMOS_COMPAT_PAYLOAD_DIR"
    cp -a "$compat_src"/. "$PMOS_COMPAT_PAYLOAD_DIR"/
  fi

  for candidate in \
    "$extracted/vendor/pmos-reference/pmos-v24.06-oneplus-fajita-hardware-reference.tar.zst" \
    "$extracted/pmos-reference/pmos-v24.06-oneplus-fajita-hardware-reference.tar.zst"; do
    if [[ -f "$candidate" ]]; then
      hw_src="$candidate"
      break
    fi
  done

  if [[ -n "$hw_src" ]]; then
    echo "Installing optional PMOS hardware reference from: ${hw_src#"$extracted/"}"
    mkdir -p "$(dirname "$PMOS_HARDWARE_REFERENCE_TARBALL")"
    cp -fL "$hw_src" "$PMOS_HARDWARE_REFERENCE_TARBALL"
  fi
}

main() {
  cd "$ROOT_DIR"

  if [[ "$FORCE" != "1" ]] && inputs_ready; then
    echo "Release inputs are already present for $PROFILE."
    print_missing_inputs
    echo
    echo "Next step:"
    echo "  scripts/install-release.sh $PROFILE"
    exit 0
  fi

  local bundle="$BUNDLE_PATH"
  if [[ -z "$bundle" ]]; then
    local url
    url="$(release_bundle_url)"
    mkdir -p "$DOWNLOAD_DIR"
    bundle="$DOWNLOAD_DIR/$ASSET_NAME"
    ensure_host_tools curl tar sha256sum
    case "$bundle" in
      *.tar.zst|*.tzst|*.zst) ensure_host_tools zstd ;;
    esac
    download_bundle "$url" "$bundle"
  else
    if [[ ! -f "$bundle" ]]; then
      echo "Bundle not found: $bundle" >&2
      exit 1
    fi
    ensure_host_tools tar sha256sum
    case "$bundle" in
      *.tar.zst|*.tzst|*.zst) ensure_host_tools zstd ;;
    esac
  fi

  verify_bundle_sha256 "$bundle"

  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/oneplus6t-release-inputs.XXXXXX")"
  RELEASE_INPUTS_TMP="$tmp"
  trap cleanup EXIT

  echo "Extracting release inputs."
  safe_extract_bundle "$bundle" "$tmp"
  verify_extracted_checksums "$tmp"
  copy_boot_artifacts "$tmp"
  copy_local_packages "$tmp"
  copy_optional_pmos_payloads "$tmp"

  echo
  print_missing_inputs

  if ! inputs_ready; then
    cat >&2 <<EOF

Release input import is incomplete.
Expected a bundle with PMOS boot artifacts and local aarch64 packages.
EOF
    exit 1
  fi

  echo
  echo "RELEASE_INPUTS_READY"
  if ! optional_payload_ready; then
    echo "WARN: optional PMOS compatibility/reference payloads are still missing."
    echo "      The image can build, but modem/Wi-Fi parity may be reduced."
  fi
  echo "Next step:"
  echo "  scripts/install-release.sh $PROFILE"
}

main
