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
  local mode="$1" dry_run="${2:-0}" marker="${3:-}"
  if [[ "$EUID" == 0 ]]; then
    # shellcheck disable=SC2016 # Expand SD_ROOT in the child shell, not this one.
    env SD_ROOT="$ROOT" SD_LOG_DIR="$log_dir" SD_MODE="$mode" SD_DRY_RUN="$dry_run" LOG_MARKER="$marker" bash -c 'source "$SD_ROOT/lib/common.sh"; init_logging; [[ -z "$LOG_MARKER" ]] || info "$LOG_MARKER"'
  else
    # shellcheck disable=SC2016 # Expand SD_ROOT in the child shell, not this one.
    sudo -n env SD_ROOT="$ROOT" SD_LOG_DIR="$log_dir" SD_MODE="$mode" SD_DRY_RUN="$dry_run" LOG_MARKER="$marker" bash -c 'source "$SD_ROOT/lib/common.sh"; init_logging; [[ -z "$LOG_MARKER" ]] || info "$LOG_MARKER"'
  fi
}

as_root() {
  if [[ "$EUID" == 0 ]]; then "$@"; else sudo -n "$@"; fi
}

run_as_root check
[[ ! -e "$log_dir" ]] || { echo "Check-only unexpectedly created a log directory" >&2; exit 1; }
run_as_root run 1
[[ ! -e "$log_dir" ]] || { echo "Dry-run unexpectedly created a log directory" >&2; exit 1; }

# Deliberately create two logs in immediate succession. A timestamp-only
# filename used to truncate the first stage's log when both started in one second.
run_as_root run 0 "stage-one-marker"
run_as_root run 0 "stage-two-marker"
mapfile -t logs < <(as_root find "$log_dir" -maxdepth 1 -type f -name 'run-*.log' | sort)
[[ "${#logs[@]}" -eq 2 ]] || { echo "Expected two distinct run logs, found ${#logs[@]}" >&2; exit 1; }
as_root grep -q "stage-one-marker" "${logs[0]}" "${logs[1]}" || { echo "First stage log marker was lost" >&2; exit 1; }
as_root grep -q "stage-two-marker" "${logs[0]}" "${logs[1]}" || { echo "Second stage log marker was lost" >&2; exit 1; }
for file in "${logs[@]}"; do
  [[ "$(as_root stat -c '%a' "$file")" == "600" ]] || { echo "Log file permissions are not 0600: $file" >&2; exit 1; }
done
[[ "$(as_root stat -c '%a' "$log_dir")" == "700" ]] || { echo "Log directory permissions are not 0700" >&2; exit 1; }

echo "Common logging mode and collision tests passed."
