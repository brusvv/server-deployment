#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
export SD_ROOT="$ROOT_DIR"

source "$ROOT_DIR/installer/menu.sh"

while true; do
  if installer_menu_select_profile; then
    [[ -f "$INSTALL_PROFILE_FILE" ]] || {
      printf 'ERROR: installation profile not found: %s\n' "$INSTALL_PROFILE_FILE" >&2
      exit 1
    }
    # shellcheck disable=SC1090
    source "$INSTALL_PROFILE_FILE"

    if installer_menu_confirm_profile; then
      break
    else
      result=$?
      if (( result == 2 )); then
        printf '\nУстановщик закрыт.\n'
        exit 0
      fi
      # "No" returns to the main menu. Invalid answers are also fail-safe.
      continue
    fi
  else
    result=$?
    if (( result == 2 )); then
      printf '\nУстановщик закрыт.\n'
      exit 0
    fi
  fi
done

printf '\nЗапуск профиля: %s\n' "$PROFILE_ID"
printf 'До подтверждения система не изменялась.\n\n'

for stage in "${PROFILE_STAGES[@]}"; do
  printf '\n========== %s ==========%s' "$stage" $'\n'
  bash "$ROOT_DIR/install.sh" --run --stage "$stage"
done

printf '\nПрофиль %s завершил все объявленные этапы.\n' "$PROFILE_ID"
printf 'Проверьте предупреждения и выполните ручные шаги, указанные установщиком.\n'
