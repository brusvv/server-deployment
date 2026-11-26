#!/usr/bin/env bash
set -Eeuo pipefail
source "$SD_ROOT/lib/common.sh"
source "$SD_ROOT/lib/config.sh"
# shellcheck disable=SC1090
load_config
require_root

create_backup() {
  local prefix="${1:-server-deployment}" stamp tmp suffix archive path relative existing covered
  local -a relative_paths=()
  for path in "$REMNAWAVE_DIR" "${MTProxyL_DIR:-/opt/mtproxyl}" "$HAPROXY_CONFIG" "$SD_ROOT/config"; do
    [[ -e "$path" || -L "$path" ]] || continue
    [[ "$path" == /* ]] || die "Backup path must be absolute: $path"
    case "/$path/" in */../*) die "Backup path contains traversal: $path";; esac
    relative="${path#/}"
    covered=0
    for existing in "${relative_paths[@]}"; do
      if [[ "$relative" == "$existing" || "$relative" == "$existing/"* ]]; then
        info "Backup path is already covered by its parent directory; skipping duplicate: $path"
        covered=1
        break
      fi
    done
    (( covered == 1 )) && continue
    relative_paths+=("$relative")
  done
  (("${#relative_paths[@]}")) || die "No configured paths exist to back up"

  if [[ "$SD_DRY_RUN" == "1" ]]; then
    info "Dry-run: would create backup of: ${relative_paths[*]}"
    return 0
  fi

  install -d -m 0700 "$BACKUP_DIR"
  chmod 0700 "$BACKUP_DIR"
  stamp="$(date -u +%Y%m%dT%H%M%S)"
  tmp="$(mktemp "$BACKUP_DIR/.${prefix}-${stamp}.XXXXXX")"
  suffix="${tmp##*.}"
  archive="$BACKUP_DIR/${prefix}-${stamp}-${suffix}.tar.gz"

  if ! tar --numeric-owner -czf "$tmp" -C / -- "${relative_paths[@]}"; then
    rm -f -- "$tmp"
    die "Backup archive creation failed"
  fi
  chmod 0600 "$tmp"
  if ! ln -- "$tmp" "$archive"; then
    rm -f -- "$tmp"
    die "Refusing to overwrite existing backup: $archive"
  fi
  rm -f -- "$tmp"
  info "Backup created: $archive"
}

list_backups() {
  [[ -d "$BACKUP_DIR" ]] || { info "No backup directory exists yet."; return 0; }
  find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.tar.gz' -printf '%TY-%Tm-%Td %TH:%TM %p\n' | sort
}

restore_backup() {
  local archive="${1:-}" safe_archive
  [[ -n "$archive" && -f "$archive" && ! -L "$archive" ]] || die "Usage: $0 restore /path/to/archive.tar.gz"
  local -a allowed_roots=()
  allowed_roots=("$REMNAWAVE_DIR" "${MTProxyL_DIR:-/opt/mtproxyl}" "$HAPROXY_CONFIG" "$SD_ROOT/config")
  install -d -m 0700 "$BACKUP_DIR"
  safe_archive="$(mktemp "$BACKUP_DIR/.restore.XXXXXX")"
  chmod 0600 "$safe_archive"
  cp -- "$archive" "$safe_archive"
  RESTORE_TEMP="$safe_archive"
  trap 'rm -f -- "${RESTORE_TEMP:-}"' EXIT

  python3 "$SD_ROOT/lib/backup_archive.py" "$safe_archive" "${allowed_roots[@]}" || die "Backup archive failed safety validation."
  confirm "Restore validated archive '$archive'? Current files will be overwritten." || exit 0

  info "Creating a pre-restore safety backup."
  create_backup "pre-restore"
  tar --numeric-owner -xzf "$safe_archive" -C /
  info "Restore completed from: $archive"
}

action="${1:-create}"
case "$action" in
  create) create_backup ;;
  list) list_backups ;;
  restore) restore_backup "${2:-}" ;;
  *) die "Usage: $0 [create|list|restore /path/to/archive.tar.gz]" ;;
esac
