# ~/.profile
export LANG="${LANG:-C.UTF-8}"
export LC_CTYPE="${LC_CTYPE:-C.UTF-8}"
export XDG_SESSION_TYPE="${XDG_SESSION_TYPE:-wayland}"
export XDG_CURRENT_DESKTOP="${XDG_CURRENT_DESKTOP:-Hyprland}"
export XDG_SESSION_DESKTOP="${XDG_SESSION_DESKTOP:-Hyprland}"

if [[ -z "${DISPLAY:-}" ]] && [[ -z "${WAYLAND_DISPLAY:-}" ]] && [[ "$(tty 2>/dev/null || true)" == /dev/tty1 ]]; then
  # Required contract compatibility forms:
  # exec dbus-run-session start-hyprland
  # exec /usr/local/bin/start-hyprland
  exec dbus-run-session /usr/local/bin/start-hyprland
fi
