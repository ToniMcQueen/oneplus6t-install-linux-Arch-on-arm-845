# ~/.bash_profile
[[ -f ~/.bashrc ]] && . ~/.bashrc

if [[ -z "${DISPLAY:-}" ]] && [[ -z "${WAYLAND_DISPLAY:-}" ]] && [[ "$(tty 2>/dev/null || true)" == /dev/tty1 ]]; then
  exec dbus-run-session start-hyprland
fi

[[ -f ~/.profile ]] && . ~/.profile
