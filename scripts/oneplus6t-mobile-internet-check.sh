#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PHONE_SSH_TARGET="${PHONE_SSH_TARGET:-alarm@172.16.42.1}"
PHONE_SSH_CONNECT_TIMEOUT="${PHONE_SSH_CONNECT_TIMEOUT:-8}"

ssh_opts=(
  -F /dev/null
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout="$PHONE_SSH_CONNECT_TIMEOUT"
  -o PubkeyAuthentication=no
  -o PreferredAuthentications=password,keyboard-interactive
  -o NumberOfPasswordPrompts=1
  -o IdentitiesOnly=yes
)

echo "== OnePlus 6T mobile internet health check =="
echo

action="${1:-host}"
case "$action" in
  host)
    :
    ;;
  shell)
    :
    ;;
  *)
    echo "Usage: $0 [host|shell]"
    echo "  host  -> check modem state + shell checks via SSH on the phone (default)"
    echo "  shell -> run only local-shell parsing helpers for docs/tests"
    exit 2
    ;;
esac

if [[ "$action" == "host" ]]; then
  ssh "${ssh_opts[@]}" "$PHONE_SSH_TARGET" 'bash -s' <<'REMOTE'
set -u

echo "== modem =="
mmcli -L || true
mmcli -m 0 --output-keyvalue || true
echo

echo "== service =="
if command -v systemctl >/dev/null 2>&1; then
  systemctl is-active oneplus6t-mobile-data.service || true
  systemctl status oneplus6t-mobile-data.service --no-pager || true
else
  echo "systemctl unavailable"
fi
echo

echo "== oneplus6t-mobile-data status =="
oneplus6t-mobile-data status || true

echo

echo "== data links =="
ip -br addr show
ip -br route show

default_iface="$(ip route | awk '$1 == "default" {for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1); exit}}}')"
if [[ -n "${default_iface:-}" ]]; then
  echo
  echo "== default interface checks (${default_iface}) =="
  ip -br addr show dev "$default_iface" || true
  ip -br route show dev "$default_iface" || true
else
  echo
  echo "default interface: not detected"
fi

echo

candidate_ifaces="$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(rmnet|qmap|wwan|wwan[0-9]+|uqmi|uwbr|qti|rmnet_ipa)' || true)"
if [[ -n "$candidate_ifaces" ]]; then
  echo "== candidate modem data interfaces =="
  echo "$candidate_ifaces"
fi

echo

echo "== DNS and internet reachability =="
for iface in rmnet0 rmnet_data0 qmapmux0 qmapmux0.0 wwan0; do
  if ip link show "$iface" >/dev/null 2>&1; then
    echo "-- ${iface}:"
    ping -c 2 -W 2 -I "$iface" 1.1.1.1 >/tmp/ping-${iface}.txt && echo "ping-ipv4: ok" || echo "ping-ipv4: fail"
    head -n 2 /tmp/ping-${iface}.txt
    if command -v curl >/dev/null 2>&1; then
      timeout 6 curl -I --interface "$iface" https://example.com >/tmp/curl-${iface}.txt 2>&1 && echo "https-via-${iface}: ok" || echo "https-via-${iface}: fail"
      grep -m 1 -Ei 'HTTP|curl' /tmp/curl-${iface}.txt || true
    else
      echo "curl: unavailable"
    fi
  fi
 done

# optional: verify interface can reach APNs/gateway via gateway route
if [[ -n "${default_iface:-}" ]]; then
  gateway="$(ip route | awk -v iface="${default_iface}" '$1=="default" && $5==iface {print $3; exit}')"
  if [[ -n "$gateway" ]]; then
    ping -c 2 -W 2 "$gateway" >/tmp/ping-gw.txt && echo "gateway ${gateway}: ok" || echo "gateway ${gateway}: fail"
    head -n 2 /tmp/ping-gw.txt
  else
    echo "default gateway: not found"
  fi
fi

rm -f /tmp/ping-*.txt /tmp/curl-*.txt

echo

echo "done"
REMOTE
  exit
fi

# local-shell parse mode for CI or scripting docs
echo "== local parse mode =="
echo "Use the 'host' mode to run on the phone."
echo "Example: bash $0 host"
