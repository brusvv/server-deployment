#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  if [[ "$EUID" == 0 ]]; then rm -rf -- "$tmp"; else sudo -n rm -rf -- "$tmp"; fi
}
trap cleanup EXIT

fixture="$tmp/fixture"
mkdir -p "$fixture/lib" "$fixture/config"
cp "$ROOT/modules/07-backup.sh" "$fixture/backup.sh"
cp "$ROOT/lib/common.sh" "$ROOT/lib/config.sh" "$fixture/lib/"
: > "$fixture/config/ports.env"
cat > "$fixture/config/services.env" <<EOF
REMNAWAVE_DIR="$tmp/nonexistent-remnawave"
MTProxyL_DIR="$tmp/nonexistent-mtproxyl"
HAPROXY_CONFIG="$tmp/nonexistent-haproxy.cfg"
BACKUP_DIR="$tmp/backups"
STATE_DIR="$tmp/state"
EOF

run_backup_dry_run() {
  if [[ "$EUID" == 0 ]]; then
    env SD_ROOT="$fixture" SD_DRY_RUN=1 SD_MODE=run bash "$fixture/backup.sh"
  else
    sudo -n env SD_ROOT="$fixture" SD_DRY_RUN=1 SD_MODE=run bash "$fixture/backup.sh"
  fi
}
run_backup_dry_run
[[ ! -e "$tmp/backups" ]] || { echo "Dry-run unexpectedly created backup directory" >&2; exit 1; }
echo "Backup dry-run tests passed."
