#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
export SD_ROOT="$ROOT_DIR"
source "$SD_ROOT/lib/common.sh"
source "$SD_ROOT/lib/config.sh"
load_config
source "$SD_ROOT/lib/remnawave-users.sh"

header() {
  printf '\n========================================\n%s\n========================================\n' "$1"
}
ok() {
  info "OK: $*"
}

require_root
for command_name in docker jq curl; do
  have "$command_name" || die "Required command not found: $command_name"
done

while true; do
  printf '\n=== Server Deployment — Remnawave ===\n'
  printf '1. Перенос пользователей Remnawave\n'
  printf '2. Аудит связанных данных Remnawave (только чтение)\n'
  printf '0. Назад\n'
  read -r -p "Выберите действие: " choice
  case "$choice" in
    1)
      if ! remnawave_users_migrate; then
        warn "Перенос завершился с ошибкой или был остановлен. Проверьте журнал и целевую панель."
      fi
      ;;
    2)
      if ! remnawave_users_related_audit; then
        warn "Аудит завершился с ошибкой или обнаружил блокирующие несоответствия."
      fi
      ;;
    0) exit 0 ;;
    *) warn "Неизвестный пункт меню." ;;
  esac
done
