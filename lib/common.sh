#!/usr/bin/env bash
set -Eeuo pipefail
: "${SD_ROOT:=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
: "${SD_MODE:=check}"
: "${SD_DRY_RUN:=0}"
_log_dir="${SD_LOG_DIR:-/var/log/server-deployment}" _log_file=""
_now(){ date -u '+%Y-%m-%dT%H:%M:%SZ'; }
_log(){
 local level="$1" line
 shift
 line="[$(_now)] [$level] $*"
 printf '%s\n' "$line" >&2
 [[ -z "$_log_file" ]] || printf '%s\n' "$line" >>"$_log_file"
}
info(){ _log INFO "$@"; }
warn(){ _log WARN "$@"; }
err(){ _log ERROR "$@"; }
die(){ err "$*"; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }
init_logging(){ [[ "${SD_MODE:-check}" == "run" ]] || return 0; if [[ "${EUID:-$(id -u)}" == 0 ]]; then install -d -m 0700 "$_log_dir"; _log_file="$_log_dir/run-$(date -u +%Y%m%dT%H%M%SZ).log"; install -m 0600 /dev/null "$_log_file"; fi; }
require_root(){ [[ "${EUID:-$(id -u)}" == 0 ]] || die "Run as root (sudo)."; }
confirm(){ [[ "$SD_MODE" == run && "$SD_DRY_RUN" == 0 ]] || { warn "Check/dry-run mode: no changes."; return 1; }; [[ "${SD_ASSUME_YES:-0}" == 1 ]] && return 0; read -r -p "$1 [y/N] " answer; [[ "$answer" =~ ^[Yy]$ ]]; }
backup_file(){
 [[ -e "$1" ]] || return 0
 local backup
 backup="$1.before-server-deployment.$(date -u +%Y%m%dT%H%M%SZ)"
 cp -a "$1" "$backup"
 chmod go-rwx "$backup" 2>/dev/null || true
 info "Backup created: $backup"
}
