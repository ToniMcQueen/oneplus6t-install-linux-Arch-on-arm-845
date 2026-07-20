#!/usr/bin/env bash

select_root_runner() {
  ROOT_RUNNER_MODE=""

  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    ROOT_RUNNER=()
    return
  fi

  if [[ -n "${ONEPLUS6T_ROOT_RUNNER:-}" ]]; then
    # shellcheck disable=SC2206
    ROOT_RUNNER=($ONEPLUS6T_ROOT_RUNNER)
    return
  fi

  if command -v doas >/dev/null 2>&1; then
    ROOT_RUNNER=(doas)
    ROOT_RUNNER_MODE="doas"
    return
  fi

  if command -v sudo >/dev/null 2>&1; then
    ROOT_RUNNER=(sudo)
    ROOT_RUNNER_MODE="sudo"
    return
  fi

  if command -v su >/dev/null 2>&1; then
    ROOT_RUNNER=(su)
    ROOT_RUNNER_MODE="su"
    return
  fi

  if command -v doas >/dev/null 2>&1; then
    echo "doas is installed but is not usable as currently configured." >&2
  fi
  if command -v sudo >/dev/null 2>&1; then
    echo "sudo is installed but is not usable as currently configured." >&2
  fi
  if command -v su >/dev/null 2>&1; then
    echo "su is installed but is not usable as currently configured." >&2
  fi

  cat >&2 <<'EOF'
This step needs root privileges, but neither doas nor sudo was found.

Install doas/sudo, run as root, or set ONEPLUS6T_ROOT_RUNNER to a compatible
privilege command.
EOF
  exit 1
}

require_root_runner() {
  select_root_runner
}

run_as_root() {
  select_root_runner
  if [[ "${#ROOT_RUNNER[@]}" -eq 0 ]]; then
    "$@"
    return
  fi

  if [[ "${ROOT_RUNNER_MODE:-}" == "su" ]]; then
    local joined
    printf -v joined '%q ' "$@"
    su -c "$joined"
  else
    "${ROOT_RUNNER[@]}" "$@"
  fi
}

run_env_as_root() {
  select_root_runner
  if [[ "${#ROOT_RUNNER[@]}" -eq 0 ]]; then
    env "$@"
    return
  fi

  if [[ "${ROOT_RUNNER_MODE:-}" == "su" ]]; then
    local joined
    printf -v joined '%q ' "${@}"
    su -c "env $joined"
  else
    "${ROOT_RUNNER[@]}" env "$@"
  fi
}
