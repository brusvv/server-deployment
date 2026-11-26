#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  if [[ "$EUID" == 0 ]]; then rm -rf -- "$tmp"; else sudo -n rm -rf -- "$tmp"; fi
}
trap cleanup EXIT

fixture="$tmp/fixture"
mkdir -p "$fixture/lib" "$fixture/config" "$tmp/remnawave" "$tmp/mtproxyl"
cp "$ROOT/modules/07-backup.sh" "$fixture/backup.sh"
cp "$ROOT/lib/common.sh" "$ROOT/lib/config.sh" "$ROOT/lib/backup_archive.py" "$fixture/lib/"
: > "$fixture/config/ports.env"
cat > "$fixture/config/services.env" <<EOF
REMNAWAVE_DIR="$tmp/remnawave"
MTProxyL_DIR="$tmp/mtproxyl"
HAPROXY_CONFIG="$tmp/haproxy.cfg"
BACKUP_DIR="$tmp/backups"
STATE_DIR="$tmp/state"
EOF
printf 'original\n' > "$tmp/remnawave/marker"
printf 'haproxy\n' > "$tmp/haproxy.cfg"

run_backup() {
  if [[ "$EUID" == 0 ]]; then
    env SD_ROOT="$fixture" SD_MODE=run SD_DRY_RUN=0 SD_ASSUME_YES=1 bash "$fixture/backup.sh" "$@"
  else
    sudo -n env SD_ROOT="$fixture" SD_MODE=run SD_DRY_RUN=0 SD_ASSUME_YES=1 bash "$fixture/backup.sh" "$@"
  fi
}

run_backup create
run_backup create
archive_count="$(find "$tmp/backups" -maxdepth 1 -type f -name 'server-deployment-*.tar.gz' | wc -l)"
[[ "$archive_count" -eq 2 ]] || { echo "Expected two uniquely named backups, found $archive_count" >&2; exit 1; }

archive="$(find "$tmp/backups" -maxdepth 1 -type f -name 'server-deployment-*.tar.gz' | sort | head -n1)"
printf 'modified\n' > "$tmp/remnawave/marker"
run_backup restore "$archive"
grep -qx 'original' "$tmp/remnawave/marker" || { echo "Restore did not recover original file" >&2; exit 1; }

find "$tmp/backups" -maxdepth 1 -type f -name 'pre-restore-*.tar.gz' | grep -q . || {
  echo "Restore did not create a pre-restore safety backup" >&2
  exit 1
}
[[ "$(stat -c '%a' "$tmp/backups")" == "700" ]] || { echo "Backup directory permissions are not 0700" >&2; exit 1; }
echo "Backup create/restore tests passed."
