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
HAPROXY_CONFIG="$tmp/mtproxyl/haproxy.cfg"
BACKUP_DIR="$tmp/backups"
STATE_DIR="$tmp/state"
EOF
printf 'original\n' > "$tmp/remnawave/marker"
printf 'haproxy\n' > "$tmp/mtproxyl/haproxy.cfg"

as_root() {
  if [[ "$EUID" == 0 ]]; then "$@"; else sudo -n "$@"; fi
}
run_backup() {
  if [[ "$EUID" == 0 ]]; then
    env SD_ROOT="$fixture" SD_MODE=run SD_DRY_RUN=0 SD_ASSUME_YES=1 bash "$fixture/backup.sh" "$@"
  else
    sudo -n env SD_ROOT="$fixture" SD_MODE=run SD_DRY_RUN=0 SD_ASSUME_YES=1 bash "$fixture/backup.sh" "$@"
  fi
}

run_backup create
run_backup create
archive_count="$(as_root find "$tmp/backups" -maxdepth 1 -type f -name 'server-deployment-*.tar.gz' | wc -l)"
[[ "$archive_count" -eq 2 ]] || { echo "Expected two uniquely named backups, found $archive_count" >&2; exit 1; }

archive="$(as_root find "$tmp/backups" -maxdepth 1 -type f -name 'server-deployment-*.tar.gz' | sort | head -n1)"
printf 'modified\n' > "$tmp/remnawave/marker"
run_backup restore "$archive"
grep -qx 'original' "$tmp/remnawave/marker" || { echo "Restore did not recover original file" >&2; exit 1; }

as_root find "$tmp/backups" -maxdepth 1 -type f -name 'pre-restore-*.tar.gz' | grep -q . || {
  echo "Restore did not create a pre-restore safety backup" >&2
  exit 1
}
[[ "$(as_root stat -c '%a' "$tmp/backups")" == "700" ]] || { echo "Backup directory permissions are not 0700" >&2; exit 1; }

# Refuse recursive backup locations and filesystem-root backup targets.
cat > "$fixture/config/services.env" <<EOF
REMNAWAVE_DIR="$tmp/remnawave"
MTProxyL_DIR="$tmp/mtproxyl"
HAPROXY_CONFIG="$tmp/mtproxyl/haproxy.cfg"
BACKUP_DIR="$tmp/mtproxyl/backups"
STATE_DIR="$tmp/state"
EOF
if run_backup create >"$tmp/nested-backup.out" 2>&1; then
  echo "Backup directory nested inside MTProxyL was unexpectedly accepted" >&2
  exit 1
fi
grep -q "BACKUP_DIR must not be inside a path being backed up" "$tmp/nested-backup.out"

cat > "$fixture/config/services.env" <<EOF
REMNAWAVE_DIR="/"
MTProxyL_DIR="$tmp/mtproxyl"
HAPROXY_CONFIG="$tmp/mtproxyl/haproxy.cfg"
BACKUP_DIR="$tmp/backups"
STATE_DIR="$tmp/state"
EOF
if run_backup create >"$tmp/root-backup.out" 2>&1; then
  echo "Filesystem root backup target was unexpectedly accepted" >&2
  exit 1
fi
grep -q "absolute non-root path" "$tmp/root-backup.out"

mkdir -p "$tmp/backups-target"
ln -s "$tmp/backups-target" "$tmp/backups-link"
cat > "$fixture/config/services.env" <<EOF
REMNAWAVE_DIR="$tmp/remnawave"
MTProxyL_DIR="$tmp/mtproxyl"
HAPROXY_CONFIG="$tmp/mtproxyl/haproxy.cfg"
BACKUP_DIR="$tmp/backups-link"
STATE_DIR="$tmp/state"
EOF
if run_backup create >"$tmp/symlink-backup.out" 2>&1; then
  echo "Symlinked BACKUP_DIR was unexpectedly accepted" >&2
  exit 1
fi
grep -q "BACKUP_DIR must not be a symlink" "$tmp/symlink-backup.out"

echo "Backup create/restore tests passed."
