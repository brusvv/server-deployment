#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
[[ "$EUID" == 0 ]] || { echo "Run as root: sudo ./manage.sh" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }
while true; do
  printf '\n=== Server Deployment — управление ===\n'
  printf '1. Cloudflare WARP / MASQUE\n'
  printf '0. Exit\n'
  read -r -p "Select: " choice
  case "$choice" in
    1) python3 "$ROOT_DIR/lib/warp_masque.py" menu ;;\n    2) bash "$ROOT_DIR/modules/09-remnawave-user-migration.sh" ;;
    0) exit 0 ;;
    *) echo "Unknown selection." ;;
  esac
done
