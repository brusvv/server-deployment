#!/usr/bin/env bash
set -Eeuo pipefail
source "$SD_ROOT/lib/common.sh"
source "$SD_ROOT/lib/config.sh"
# shellcheck disable=SC1090
load_config
require_root
action="${1:-create}"
install -d -m 0700 "$BACKUP_DIR"
case "$action" in
 create)
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  archive="$BACKUP_DIR/server-deployment-$stamp.tar.gz"
  paths=()
  for path in "$REMNAWAVE_DIR" "$MTProxyL_DIR" "$HAPROXY_CONFIG" "$SD_ROOT/config"; do [[ -e "$path" ]] && paths+=("$path"); done
  (("${#paths[@]}")) || die "No configured paths exist to back up"
  tar --numeric-owner -czf "$archive" "${paths[@]}"
  chmod 0600 "$archive"
  info "Backup created: $archive"
  ;;
 list) find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.tar.gz' -printf '%TY-%Tm-%Td %TH:%TM %p\n' | sort;;
 restore)
  [[ -n "${2:-}" && -f "$2" ]] || die "Usage: $0 restore /path/to/archive.tar.gz"
  tar -tzf "$2"
  confirm "Restore this archive to filesystem root? Existing files may be overwritten." || exit 0
  tar --numeric-owner -xzf "$2" -C /
  ;;
 *) die "Usage: $0 [create|list|restore /path/to/archive.tar.gz]";;
esac
