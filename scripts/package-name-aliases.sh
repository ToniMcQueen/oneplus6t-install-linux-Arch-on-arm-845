#!/usr/bin/env bash

normalize_profile_package_name() {
  case "$1" in
    adb|fastboot)
      printf '%s\n' android-tools
      ;;
    *)
      printf '%s\n' "$1"
      ;;
  esac
}

describe_profile_package_alias() {
  case "$1" in
    adb|fastboot)
      printf '%s\n' "$1 is installed by the Arch package android-tools"
      ;;
    *)
      return 1
      ;;
  esac
}
