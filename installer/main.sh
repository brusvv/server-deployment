#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
export SD_ROOT="$ROOT_DIR"

source "$ROOT_DIR/installer/menu.sh"

while true; do
  if installer_menu_select_profile; then
    [[ -f "$INSTALL_PROFILE_FILE" ]] || {
      printf 'ERROR: installation profile not found: %s\\n' "$INSTALL_PROFILE_FILE" >&2
      exit 1
    }
    # shellcheck disable=SC1090
    source "$INSTALL_PROFILE_FILE"

    if installer_menu_confirm_profile; then
      break
    else
      result=$?
      if (( result == 2 )); then
        printf '\\nУстановщик закрыт.\\n'
        exit 0
      fi
      continue
    fi
  else
    result=$?
    if (( result == 2 )); then
      printf '\\nУстановщик закрыт.\\n'
      exit 0
    fi
  fi
done

if [[ "${EUID:-$(id -u)}" != 0 ]]; then
  printf 'ERROR: run the installer as root (sudo ./install.sh).\\n' >&2
  exit 1
fi

printf '\\nЗапуск профиля: %s\\n' "$PROFILE_ID"
printf 'До подтверждения система не изменялась.\\n\\n'

skipped_stages=()
for stage in "${PROFILE_STAGES[@]}"; do
  printf '\\n========== %s ==========\\n' "$stage"
  if bash "$ROOT_DIR/install.sh" --run --stage "$stage"; then
    printf 'Результат этапа %s: успешно.\\n' "$stage"
  else
    result=$?
    if (( result == 10 )) && [[ " ${PROFILE_OPTIONAL_STAGES[*]:-} " == *" $stage "* ]]; then
      skipped_stages+=("$stage")
      printf 'Результат этапа %s: пропущен (необязательный этап).\\n' "$stage"
      continue
    fi
    printf 'ERROR: этап %s завершился с кодом %s; профиль остановлен.\\n' "$stage" "$result" >&2
    exit "$result"
  fi
done

if (("${#skipped_stages[@]}" > 0)); then
  printf '\\nПрофиль %s завершил обязательные этапы.\\n' "$PROFILE_ID"
  printf 'Не выполнены необязательные этапы: %s\\n' "${skipped_stages[*]}"
  printf 'Профиль не следует считать полностью развёрнутым до выполнения этих компонентов.\\n'
else
  printf '\\nПрофиль %s завершил все объявленные этапы.\\n' "$PROFILE_ID"
fi
