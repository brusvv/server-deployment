#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
[[ "$EUID" == 0 ]] || { echo "Run as root: sudo ./manage.sh" >&2; exit 1; }
export SD_MODE="${SD_MODE:-run}" SD_DRY_RUN="${SD_DRY_RUN:-0}"
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }
while true; do
  printf '\n=== Server Deployment — управление ===\n'
  printf '1. Cloudflare WARP / MASQUE\n'
  printf '2. Backup / restore\n'
  printf '0. Exit\n'
  read -r -p "Select: " choice
  case "$choice" in
    1) python3 "$ROOT_DIR/lib/warp_masque.py" menu ;;
    2)
      while true; do
        printf '\n=== Резервные копии ===\n'
        printf '1. Создать резервную копию\n'
        printf '2. Показать резервные копии\n'
        printf '3. Восстановить из архива\n'
        printf '0. Назад\n'
        read -r -p "Select: " backup_choice
        case "$backup_choice" in
          1) bash "$ROOT_DIR/modules/07-backup.sh" create ;;
          2) bash "$ROOT_DIR/modules/07-backup.sh" list ;;
          3)
            read -r -p "Archive path: " archive_path
            [[ -n "$archive_path" ]] && bash "$ROOT_DIR/modules/07-backup.sh" restore "$archive_path"
            ;;
          0) break ;;
          *) echo "Unknown selection." ;;
        esac
      done
      ;;
    0) exit 0 ;;
    *) echo "Unknown selection." ;;
  esac
done
