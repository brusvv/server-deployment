#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
test_root="$tmp/root"
mkdir -p "$test_root/config"
: > "$test_root/config/services.env"

write_ports(){ printf '%s\n' "$1" > "$test_root/config/ports.env"; }
load_values(){
  SD_ROOT="$test_root" ROOT="$ROOT" bash -c '
    set -Eeuo pipefail
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    load_config
    printf "%s|%s\n" "$SS_BRIDGE_ENABLED" "$SS_BRIDGE_PORT"
  '
}

write_ports 'SS_BRIDGE_PORT="9999"'
[[ "$(load_values)" == "0|9999" ]]

write_ports $'SS_BRIDGE_ENABLED="1"\nSS_BRIDGE_PORT="24443"'
[[ "$(load_values)" == "1|24443" ]]

write_ports $'SS_BRIDGE_ENABLED="0"\nSS_BRIDGE_PORT="08080"'
[[ "$(load_values)" == "0|8080" ]]

write_ports $'SS_BRIDGE_ENABLED="yes"\nSS_BRIDGE_PORT="9999"'
if load_values >/dev/null 2>&1; then
  echo "Invalid SS_BRIDGE_ENABLED unexpectedly passed" >&2
  exit 1
fi

write_ports $'SS_BRIDGE_ENABLED="1"\nSS_BRIDGE_PORT="65536"'
if load_values >/dev/null 2>&1; then
  echo "Out-of-range SS_BRIDGE_PORT unexpectedly passed" >&2
  exit 1
fi

write_ports $'SS_BRIDGE_ENABLED="0"\nSS_BRIDGE_PORT="abc"'
if load_values >/dev/null 2>&1; then
  echo "Non-numeric SS_BRIDGE_PORT unexpectedly passed" >&2
  exit 1
fi

write_ports 
if load_values >/dev/null 2>&1; then
  echo "Reserved node-control port 2222 unexpectedly passed" >&2
  exit 1
fi

echo "Cascade bridge config tests passed."
SS_BRIDGE_ENABLED="0"\nSS_BRIDGE_PORT="2222"'
if load_values >/dev/null 2>&1; then
  echo "Reserved node-control port 2222 unexpectedly passed" >&2
  exit 1
fi

echo "Cascade bridge config tests passed."
