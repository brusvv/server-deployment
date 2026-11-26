#!/usr/bin/env bash
# Interactive scenario selection. This file only selects a profile; it never
# performs system changes.
set -Eeuo pipefail
# Profile path is consumed by installer/main.sh after this file is sourced.
# shellcheck disable=SC2034

installer_menu_read() {
  local prompt="$1" answer
  [[ -r /dev/tty && -w /dev/tty ]] || return 1
  read -r -p "$prompt" answer </dev/tty || return 1
  printf '%s' "$answer"
}

installer_menu_select_profile() {
  local choice role
  while true; do
    printf '\n========================================\n'
    printf '       SERVER DEPLOYMENT\n'
    printf '========================================\n'
    printf '\nУстановка:\n'
    printf '  1. Один сервер\n'
    printf '     Remnawave / MTProxyL / HAProxy\n'
    printf '\n  2. Каскад Remnawave\n'
    printf '     VPS A — Entry; VPS B — Panel + Exit\n'
    printf '\n  0. Выход\n\n'
    choice="$(installer_menu_read 'Выберите сценарий [1/2/0]: ')" || return 2
    case "$choice" in
      1)
        INSTALL_PROFILE_FILE="$SD_ROOT/profiles/single-server/profile.sh"
        return 0
        ;;
      2)
        while true; do
          printf '\nКаскад Remnawave\n'
          printf '  1. VPS A — Entry (Россия)\n'
          printf '  2. VPS B — Panel + Exit (зарубежный сервер)\n'
          printf '  0. Назад\n\n'
          role="$(installer_menu_read 'Выберите роль [1/2/0]: ')" || return 2
          case "$role" in
            1)
              INSTALL_PROFILE_FILE="$SD_ROOT/profiles/remnawave-cascade/entry.sh"
              return 0
              ;;
            2)
              INSTALL_PROFILE_FILE="$SD_ROOT/profiles/remnawave-cascade/exit-panel.sh"
              return 0
              ;;
            0) break ;;
            *) printf 'Некорректный выбор.\n' ;;
          esac
        done
        ;;
      0) return 2 ;;
      *) printf 'Некорректный выбор.\n' ;;
    esac
  done
}

installer_menu_confirm_profile() {
  local choice
  printf '\nВыбран сценарий: %s\n' "$PROFILE_TITLE"
  printf '%s\n' "$PROFILE_DESCRIPTION"
  printf '\nБудут запущены этапы:\n'
  printf '  - %s\n' "${PROFILE_STAGES[@]}"
  while true; do
    printf '\n  1. Да — начать\n'
    printf '  2. Нет — вернуться в главное меню\n'
    printf '  0. Выход в командную оболочку\n\n'
    choice="$(installer_menu_read 'Подтвердите выбор [1/2/0]: ')" || return 2
    case "$choice" in
      1) return 0 ;;
      2) return 1 ;;
      0) return 2 ;;
      *) printf 'Некорректный выбор.\n' ;;
    esac
  done
}
