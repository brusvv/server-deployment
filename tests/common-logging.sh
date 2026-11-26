#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
log_dir="$tmp/logs"

run_as_root() {
  if [[ "$EUID" == 0 ]]; then
    env SD_ROOT="$ROOT" SD_LOG_DIR="$log_dir" SD_MODE="$1" bash -c 'source "$SD_ROOT/lib/common.sh"; init_logging'
  else
    sudo -n env SD_ROOT="$ROOT" SD_LOG_DIR="$log_dir" SD_MODE="$1" bash -c 'source "$SD_ROOT/lib/common.sh"; init_logging'
  fi
}

run_as_root check
[[ ! -e "$log_dir" ]] || { echo "Check-only unexpectedly created a log directory" >&2; exit 1; }

run_as_root run
[[ -d "$log_dir" ]]
find "$log_dir" -maxdepth 1 -type f -name 'run-*.log' | grep -q .
echo "Common logging mode tests passed."
