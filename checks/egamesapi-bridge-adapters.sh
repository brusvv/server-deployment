#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
MODE=""
CONFIG_FILE=""
MODULE=""

usage() {
  cat <<'USAGE'
Usage:
  bash checks/egamesapi-bridge-adapters.sh --check --config-file /absolute/path/config/ports.env --module /absolute/path/server_routing.sh
  sudo bash checks/egamesapi-bridge-adapters.sh --apply --config-file /absolute/path/config/ports.env --module /absolute/path/server_routing.sh

--check validates both adapter patches on a temporary copy only.
--apply asks for the exact word APPLY, then applies both patches in order.
USAGE
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --check|--apply)
      [[ -z "$MODE" ]] || die "Choose exactly one of --check or --apply."
      MODE="${1#--}"
      ;;
    --config-file)
      shift
      (($#)) || die "--config-file requires a path."
      CONFIG_FILE="$1"
      ;;
    --module)
      shift
      (($#)) || die "--module requires a path."
      MODULE="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
  shift
done

[[ -n "$MODE" ]] || die "Select --check or --apply."
[[ "$CONFIG_FILE" = /* ]] || die "--config-file must be an absolute path."
[[ "$MODULE" = /* ]] || die "--module must be an absolute path."
[[ -f "$CONFIG_FILE" && ! -L "$CONFIG_FILE" ]] || die "Config file missing, not regular, or a symlink: $CONFIG_FILE"
[[ -f "$MODULE" && ! -L "$MODULE" ]] || die "eGamesAPI module missing, not regular, or a symlink: $MODULE"
command -v python3 >/dev/null 2>&1 || die "python3 is required."

LOCAL_PATCH="$ROOT/checks/egamesapi-local-exit-compat.py"
BRIDGE_PATCH="$ROOT/checks/egamesapi-bridge-integration.py"
[[ -f "$LOCAL_PATCH" && -f "$BRIDGE_PATCH" ]] || die "Adapter patcher scripts are missing from this checkout."

printf 'Checking the exact local-Exit compatibility context...\n'
python3 "$LOCAL_PATCH" --check "$MODULE"

tmp_dir="$(mktemp -d)"
tmp_module="$tmp_dir/server_routing.sh"
original_module="$tmp_dir/server_routing.original.sh"
rollback_required=0

restore_original_module() {
  local restore_tmp
  restore_tmp="$(mktemp "${MODULE}.rollback.XXXXXX")" || return 1
  if ! cp -p -- "$original_module" "$restore_tmp"; then
    rm -f -- "$restore_tmp"
    return 1
  fi
  if ! mv -f -- "$restore_tmp" "$MODULE"; then
    rm -f -- "$restore_tmp"
    return 1
  fi
  printf 'ROLLBACK: original eGamesAPI module restored from the transaction snapshot.\n' >&2
}

on_exit() {
  local status=$?
  trap - EXIT
  if (( status != 0 && rollback_required == 1 )); then
    if ! restore_original_module; then
      printf 'CRITICAL: automatic rollback failed; restore the original module from %s manually.\n' "$original_module" >&2
      printf 'The transaction snapshot is being retained at: %s\n' "$original_module" >&2
      exit 90
    fi
  fi
  rm -rf -- "$tmp_dir"
  exit "$status"
}
trap on_exit EXIT
cp -p -- "$MODULE" "$tmp_module"

# Simulate the first patch on an isolated copy. This validates the second
# patcher's expected post-compatibility context without touching the real file.
printf 'APPLY\n' | python3 "$LOCAL_PATCH" --apply "$tmp_module" >/dev/null

printf 'Checking the managed bridge toggle, port and direct-mode adapter...\n'
python3 "$BRIDGE_PATCH" --check --config-file "$CONFIG_FILE" "$tmp_module"

if [[ "$MODE" == "check" ]]; then
  printf 'CHECK ONLY: both patches fit the installed module; no live file was changed.\n'
  exit 0
fi

read -r -p "Type APPLY to back up and patch the installed eGamesAPI module: " answer
[[ "$answer" == "APPLY" ]] || {
  printf 'Cancelled; no live file was changed.\n'
  exit 0
}

cp -p -- "$MODULE" "$original_module"
rollback_required=1

printf 'Applying local-Exit compatibility patch...\n'
printf 'APPLY\n' | python3 "$LOCAL_PATCH" --apply "$MODULE"

printf 'Applying bridge toggle, port and direct-mode adapter...\n'
printf 'APPLY\n' | python3 "$BRIDGE_PATCH" --apply --config-file "$CONFIG_FILE" "$MODULE"

printf 'Verifying the resulting module...\n'
python3 "$LOCAL_PATCH" --check "$MODULE"
python3 "$BRIDGE_PATCH" --check --config-file "$CONFIG_FILE" "$MODULE"

rollback_required=0
printf 'DONE: both guarded adapters are installed. No Remnawave API object, Node, profile, inbound, user, squad, firewall rule or service was changed.\n'
