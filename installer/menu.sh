#!/usr/bin/env bash
# Interactive menus only collect choices; installation stages run after confirmation.
set -Eeuo pipefail

_menu_use_color=0
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then _menu_use_color=1; fi

_menu_style() { if [[ "$_menu_use_color" == "1" ]]; then printf '\033[%sm' "$1"; fi; }
_menu_reset() { [[ "$_menu_use_color" == "1" ]] && printf '\033[0m'; return 0; }
_menu_t() { printf '%s' "${MENU_TEXT[$1]:-$1}"; }

_menu_load_language() {
  local selected="${SD_LANGUAGE:-}" user_home="${HOME:-/root}" config_home file
  if [[ -n "${SUDO_USER:-}" ]]; then
    user_home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)"
    user_home="${user_home:-/root}"
  fi
  config_home="${XDG_CONFIG_HOME:-$user_home/.config}"
  file="$config_home/server-deployment/selected_language"
  if [[ "$selected" != "ru" && "$selected" != "en" ]]; then
    if [[ -r "$file" ]]; then IFS= read -r selected < "$file" || true; fi
  fi
  if [[ "$selected" != "ru" && "$selected" != "en" ]]; then selected=""; fi
  if [[ -z "$selected" ]]; then
    _menu_title "$( _menu_t language_title )"
    printf '\n  %s\n\n' "$(_menu_t language_prompt)"
    _menu_option '1.' 'English'
    _menu_option '2.' 'Русский'
    printf '\n'
    local choice
    choice="$(installer_menu_read '  Select [1/2]: ')" || return 1
    case "$choice" in 1) selected=en ;; 2) selected=ru ;; *) _menu_warn "$(_menu_t invalid)"; return 1 ;; esac
    mkdir -p "$(dirname "$file")"
    chmod 700 "$(dirname "$file")"
    printf '%s\n' "$selected" > "$file"
    chmod 600 "$file"
  fi
  # shellcheck disable=SC1090
  source "$SD_ROOT/installer/lang/$selected.sh"
  export SD_LANGUAGE="$selected"
  printf '\n  %s\n' "$(_menu_t language_saved)"
}

_menu_title() {
  local title="$1" subtitle="${2:-}"
  printf '\n'
  _menu_style '1;36'; printf '  %s' "$(_menu_t brand)"; _menu_reset
  _menu_style '2'; printf '  %s' "$(_menu_t subtitle)"; _menu_reset
  printf '\n  ──────────────────────────────────────────────────────\n'
  printf '  %s\n' "$title"
  [[ -z "$subtitle" ]] || printf '  %s\n' "$subtitle"
}
_menu_status_value() {
  local label="$1" value="$2" tone="${3:-}"
  printf '  %-15s ' "$label"
  case "$tone" in good) _menu_style '32' ;; warn) _menu_style '33' ;; bad) _menu_style '31' ;; *) _menu_style '2' ;; esac
  printf '%s' "$value"; _menu_reset; printf '\n'
}
_menu_show_status() {
  local host os docker panel
  host="$(hostname -f 2>/dev/null || hostname 2>/dev/null || printf 'unknown')"
  os='unknown'
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release; os="${PRETTY_NAME:-unknown}"; fi
  if command -v docker >/dev/null 2>&1; then docker="$(_menu_t docker_found)"; else docker="$(_menu_t docker_missing)"; fi
  if [[ -f /opt/remnawave/docker-compose.yml || -f /opt/remnawave/compose.yml ]]; then panel="$(_menu_t compose_found)"; else panel="$(_menu_t compose_missing)"; fi
  printf '\n'; _menu_style '1'; printf '  %s' "$(_menu_t server_status)"; _menu_reset; printf '\n'
  _menu_status_value "$(_menu_t host)" "$host"
  _menu_status_value "$(_menu_t os)" "$os"
  if [[ "$docker" == "$(_menu_t docker_found)" ]]; then _menu_status_value "$(_menu_t docker)" "$docker" good; else _menu_status_value "$(_menu_t docker)" "$docker" warn; fi
  if [[ "$panel" == "$(_menu_t compose_found)" ]]; then _menu_status_value "$(_menu_t compose)" "$panel" good; else _menu_status_value "$(_menu_t compose)" "$panel" warn; fi
  printf '  ──────────────────────────────────────────────────────\n'
}
_menu_section() { _menu_style '1;37'; printf '\n  %s\n' "$1"; _menu_reset; }
_menu_option() {
  local number="$1" title="$2" description="${3:-}"
  _menu_style '1;36'; printf '  %s' "$number"; _menu_reset
  printf '  %s\n' "$title"
  [[ -z "$description" ]] || printf '      %s\n' "$description"
}
_menu_warn() { _menu_style '33'; printf '  WARN: %s\n' "$*"; _menu_reset; }

installer_menu_read() {
  local prompt="$1" answer
  [[ -r /dev/tty && -w /dev/tty ]] || return 1
  read -r -p "$prompt" answer </dev/tty || return 1
  printf '%s' "$answer"
}

installer_menu_main() {
  local choice
  while true; do
    _menu_title "$(_menu_t main_title)" "$(_menu_t main_subtitle)"
    _menu_show_status
    _menu_section "$(_menu_t main_title)"
    _menu_option '1.' "$(_menu_t install)" "$(_menu_t install_desc)"
    _menu_option '2.' "$(_menu_t manage)" "$(_menu_t manage_desc)"
    printf '\n  ──────────────────────────────────────────────────────\n'
    _menu_option '0.' "$(_menu_t exit)"
    printf '\n'
    choice="$(installer_menu_read "  $(_menu_t choice) [1/2/0]: ")" || return 2
    case "$choice" in 1) return 0 ;; 2) return 1 ;; 0) return 2 ;; *) _menu_warn "$(_menu_t invalid)" ;; esac
  done
}

installer_menu_select_profile() {
  local choice role
  while true; do
    _menu_title "$(_menu_t install_title)"
    _menu_show_status
    _menu_section "$(_menu_t install_section)"
    _menu_option '1.' "$(_menu_t single)" "$(_menu_t single_desc)"
    _menu_option '2.' "$(_menu_t extended)" "$(_menu_t extended_desc)"
    _menu_option '3.' "$(_menu_t cascade)" "$(_menu_t cascade_desc)"
    printf '\n  ──────────────────────────────────────────────────────\n'
    _menu_option '0.' "$(_menu_t exit)"
    printf '\n'
    choice="$(installer_menu_read "  $(_menu_t choice) [1–3/0]: ")" || return 2
    case "$choice" in
      1) export INSTALL_PROFILE_FILE="$SD_ROOT/profiles/remnawave-standard/profile.sh"; return 0 ;;
      2) export INSTALL_PROFILE_FILE="$SD_ROOT/profiles/remnawave-extended/profile.sh"; return 0 ;;
      3)
        while true; do
          _menu_title "$(_menu_t cascade_title)"
          _menu_section "$(_menu_t cascade_role)"
          _menu_option '1.' "$(_menu_t entry)" "$(_menu_t entry_desc)"
          _menu_option '2.' "$(_menu_t exit_panel)" "$(_menu_t exit_panel_desc)"
          printf '\n  ──────────────────────────────────────────────────────\n'
          _menu_option '0.' "$(_menu_t back)"
          printf '\n'
          role="$(installer_menu_read "  $(_menu_t choice) [1/2/0]: ")" || return 2
          case "$role" in
            1) export INSTALL_PROFILE_FILE="$SD_ROOT/profiles/remnawave-cascade/entry.sh"; return 0 ;;
            2) export INSTALL_PROFILE_FILE="$SD_ROOT/profiles/remnawave-cascade/exit-panel.sh"; return 0 ;;
            0) break ;;
            *) _menu_warn "$(_menu_t invalid)" ;;
          esac
        done
        ;;
      0) return 2 ;;
      *) _menu_warn "$(_menu_t invalid)" ;;
    esac
  done
}

installer_menu_confirm_profile() {
  local choice
  _menu_title "$(_menu_t confirm_title)"
  printf '\n'; _menu_style '1;37'; printf '  %s\n' "$PROFILE_TITLE"; _menu_reset
  printf '  %s\n' "$PROFILE_DESCRIPTION"
  _menu_section "$(_menu_t stages)"
  printf '  %s\n' "$(_menu_t required_stages)"
  printf '  - %s\n' "${PROFILE_STAGES[@]}"
  if declare -p PROFILE_OPTIONAL_STAGES >/dev/null 2>&1 && (("${#PROFILE_OPTIONAL_STAGES[@]}" > 0)); then
    printf '\n  %s\n' "$(_menu_t optional_stages)"
    printf '  - %s\n' "${PROFILE_OPTIONAL_STAGES[@]}"
  fi
  printf '\n  %s\n' "$(_menu_t no_changes)"
  printf '  ──────────────────────────────────────────────────────\n'
  while true; do
    _menu_option '1.' "$(_menu_t start)"
    _menu_option '2.' "$(_menu_t return)"
    _menu_option '0.' "$(_menu_t exit)"
    printf '\n'
    choice="$(installer_menu_read "  $(_menu_t choice) [1/2/0]: ")" || return 2
    case "$choice" in 1) return 0 ;; 2) return 1 ;; 0) return 2 ;; *) _menu_warn "$(_menu_t invalid)" ;; esac
  done
}
