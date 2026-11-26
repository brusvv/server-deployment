#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  if [[ "$EUID" == 0 ]]; then rm -rf -- "$tmp"; else sudo -n rm -rf -- "$tmp"; fi
}
trap cleanup EXIT
log_dir="$tmp/logs"

run_as_root() {
  local mode="$1" dry_run="${2:-0}"
  if [[ "$EUID" == 0 ]]; then
    # shellcheck disable=SC2016 # Expand SD_ROOT in the child shell, not this one.
    env SD_ROOT="$ROOT" SD_LOG_DIR="$log_dir" SD_MODE="$mode" SD_DRY_RUN="$dry_run" bash -c 'source "$SD_ROOT/lib/common.sh"; init_logging'
  else
    # shellcheck disable=SC2016 # Expand SD_ROOT in the child shell, not this one.
    sudo -n env SD_ROOT="$ROOT" SD_LOG_DIR="$log_dir" SD_MODE="$1" bash -c 'source "$SD_ROOT/lib/common.sh"; init_logging'
  fi
}

run_as_root check
[[ ! -e "$log_dir" ]] || { echo "Check-only unexpectedly created a log directory" >&2; exit 1; }
run_as_root run 1
[[ ! -e "$log_dir" ]] || { echo "Dry-run unexpectedly created a log directory" >&2; exit 1; }

run_as_root run 0
if [[ "$EUID" == 0 ]]; then
  [[ -d "$log_dir" ]]
  find "$log_dir" -maxdepth 1 -type f -name 'run-*.log' | grep -q .
else
  sudo -n test -d "$log_dir"
  sudo -n find "$log_dir" -maxdepth 1 -type f -name 'run-*.log' | grep -q .
fi
echo "Common logging mode tests passed."
