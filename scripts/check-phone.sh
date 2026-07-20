#!/usr/bin/env bash
set -euo pipefail

echo "== Host tools =="
if command -v adb >/dev/null 2>&1; then
  echo "adb: $(command -v adb)"
else
  echo "adb: missing"
fi

if command -v fastboot >/dev/null 2>&1; then
  echo "fastboot: $(command -v fastboot)"
else
  echo "fastboot: missing"
fi

echo
echo "== USB devices =="
lsusb | sort

echo
echo "== ADB devices =="
if command -v adb >/dev/null 2>&1; then
  adb devices -l || true
else
  echo "adb not installed"
fi

echo
echo "== Fastboot devices =="
if command -v fastboot >/dev/null 2>&1; then
  fastboot devices -l || true
else
  echo "fastboot not installed"
fi

echo
echo "This script only checks detection. It does not unlock, wipe, or flash the phone."
