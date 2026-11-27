#!/usr/bin/env bash
# Interactive scenario selection. This file only selects a profile; it never
# performs system changes.
set -Eeuo pipefail
# Profile path is consumed by installer/main.sh after this file is sourced.
# shellcheck disable=SC2034

_menu_use_color=0
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  _menu_use_color=1
fi

_menu_style() {
  local code="$1"
  if [[ "$_menu_use_color" == "1" ]]; then
    printf '\033[%sm' "$code"
  fi
}

_menu_reset() {
  [[ "$_menu_use_color" == "1" ]] && printf '\033[0m'
  return 0
}

_menu_title() {
  local title="$1" subtitle="${2:-}"
  printf '\n'
  _menu_style '1;36'; printf '  SERVER DEPLOYMENT'; _menu_reset
  _menu_style '2'; printf '  /  INSTALLATION MANAGER'; _menu_reset
  printf '\n  ──────────────────────────────────────────────────────\n'
  printf '  %s\n' "$title"
  [[ -z "$subtitle" ]] || printf '  %s\n' "$subtitle"
}

_menu_status_value() {
  local label="$1" value="$2" tone="${3:-}"
  printf '  %-15s ' "$label"
  case "$tone" in
    good) _menu_style '32' ;;
    warn) _menu_style '33' ;;
    bad)  _menu_style '31' ;;
    *)    _menu_style '2' ;;
  esac
  printf '%s' "$value"
  _menu_reset
  printf '\n'
}

_menu_show_status() {
  local host os docker panel
  host="$(hostname -f 2>/dev/null || hostname 2>/dev/null || printf 'unknown')"
  os='unknown'
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    os="${PRETTY_NAME:-unknown}"
  fi

  if command -v docker >/dev/null 2>&1; then
    docker='доступен'
  else
    docker='не установлен'
  fi

  if [[ -f /opt/remnawave/docker-compose.yml || -f /opt/remnawave/compose.yml ]]; then
    panel='найдена конфигурация'
  else
    panel='не обнаружена'
  fi

  printf '\n'
  _menu_style '1'; printf '  СОСТОЯНИЕ СЕРВЕРА'; _menu_reset
  printf '\n'
  _menu_status_value 'Хост:' "$host"
  _menu_status_value 'ОС:' "$os"
  if [[ "$docker" == 'доступен' ]]; then
    _menu_status_value 'Docker:' "$docker" good
  else
    _menu_status_value 'Docker:' "$docker" warn
  fi
  if [[ "$panel" == 'найдена конфигурация' ]]; then
    _menu_status_value 'Remnawave:' "$panel" good
  else
    _menu_status_value 'Remnawave:' "$panel" warn
  fi
  printf '  ──────────────────────────────────────────────────────\n'
}

_menu_section() {
  _menu_style '1;37'; printf '\n  %s\n' "$1"; _menu_reset
}

_menu_option() {
  local number="$1" title="$2" description="${3:-}"
  _menu_style '1;36'; printf '  %s' "$number"; _menu_reset
  printf '  %s\n' "$title"
  [[ -z "$description" ]] || printf '      %s\n' "$description"
}

_menu_warn() {
  _menu_style '33'; printf '  WARN: %s\n' "$*"; _menu_reset
}

installer_menu_read() {
  local prompt="$1" answer
  [[ -r /dev/tty && -w /dev/tty ]] || return 1
  read -r -p "$prompt" answer </dev/tty || return 1
  printf '%s' "$answer"
}

installer_menu_select_profile() {
  local choice role
  while true; do
    _menu_title 'Выберите конфигурацию для этого сервера'
    _menu_show_status

    _menu_section 'УСТАНОВКА REMNAWAVE'
    _menu_option '1.' 'Одиночный сервер' 'Panel + Node, без дополнительных компонентов'
    _menu_option '2.' 'Расширенная установка' 'Panel + Node и дополнительные компоненты'
    _menu_option '3.' 'Каскадная установка' 'Выбор роли VPS A (Entry) или VPS B (Panel + Exit)'

    printf '\n  ──────────────────────────────────────────────────────\n'
    _menu_option '0.' 'Выход'
    printf '\n'
    choice="$(installer_menu_read '  Ваш выбор [1–3/0]: ')" || return 2
    case "$choice" in
      1)
        export INSTALL_PROFILE_FILE="$SD_ROOT/profiles/remnawave-standard/profile.sh"
        return 0
        ;;
      2)
        export INSTALL_PROFILE_FILE="$SD_ROOT/profiles/remnawave-extended/profile.sh"
        return 0
        ;;
      3)
        while true; do
          _menu_title 'КАСКАДНАЯ УСТАНОВКА'
          _menu_section 'ВЫБЕРИТЕ РОЛЬ ЭТОГО VPS'
          _menu_option '1.' 'VPS A — Entry' 'Входной сервер'
          _menu_option '2.' 'VPS B — Panel + Exit' 'Панель управления и выходной сервер'
          printf '\n  ──────────────────────────────────────────────────────\n'
          _menu_option '0.' 'Назад'
          printf '\n'
          role="$(installer_menu_read '  Ваша роль [1/2/0]: ')" || return 2
          case "$role" in
            1)
              export INSTALL_PROFILE_FILE="$SD_ROOT/profiles/remnawave-cascade/entry.sh"
              return 0
              ;;
            2)
              export INSTALL_PROFILE_FILE="$SD_ROOT/profiles/remnawave-cascade/exit-panel.sh"
              return 0
              ;;
            0) break ;;
            *) _menu_warn 'Некорректный выбор. Повторите.' ;;
          esac
        done
        ;;
      0) return 2 ;;
      *) _menu_warn 'Некорректный выбор. Повторите.' ;;
    esac
  done
}

installer_menu_confirm_profile() {
  local choice
  _menu_title 'ПОДТВЕРЖДЕНИЕ УСТАНОВКИ'
  printf '\n'
  _menu_style '1;37'; printf '  %s\n' "$PROFILE_TITLE"; _menu_reset
  printf '  %s\n' "$PROFILE_DESCRIPTION"
  _menu_section 'ЭТАПЫ УСТАНОВКИ'
  printf '  Обязательные и выбранные этапы:\n'
  printf '  - %s\n' "${PROFILE_STAGES[@]}"
  if declare -p PROFILE_OPTIONAL_STAGES >/dev/null 2>&1 && (("${#PROFILE_OPTIONAL_STAGES[@]}" > 0)); then
    printf '\n  Необязательные этапы:\n'
    printf '  - %s\n' "${PROFILE_OPTIONAL_STAGES[@]}"
  fi
  printf '\n  До подтверждения изменения системы не выполняются.\n'
  printf '  ──────────────────────────────────────────────────────\n'
  while true; do
    _menu_option '1.' 'Да — начать установку'
    _menu_option '2.' 'Нет — вернуться к выбору'
    _menu_option '0.' 'Выход'
    printf '\n'
    choice="$(installer_menu_read '  Подтвердите выбор [1/2/0]: ')" || return 2
    case "$choice" in
      1) return 0 ;;
      2) return 1 ;;
      0) return 2 ;;
      *) _menu_warn 'Некорректный выбор. Повторите.' ;;
    esac
  done
}
