#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
export SD_ROOT="$ROOT_DIR"

if [[ ! -t 0 || ! -t 1 ]]; then
  printf "ERROR: server management requires an interactive terminal.\\n" >&2
  exit 2
fi

source "$ROOT_DIR/installer/menu.sh"
source "$ROOT_DIR/installer/lang/en.sh"

while ! _menu_load_language; do
  _menu_warn "$(_menu_t invalid)"
done

if [[ "${EUID:-$(id -u)}" != 0 ]]; then
  _menu_warn "$(_menu_t manage_root_required)"
  exit 0
fi

source "$ROOT_DIR/lib/common.sh"
source "$ROOT_DIR/lib/config.sh"
export SD_MODE=run SD_DRY_RUN=0
load_config

manage_pause() {
  printf '\n'
  installer_menu_read "  $(_menu_t press_enter) " >/dev/null || true
}

manage_run() {
  local description="$1"
  shift
  printf '\n  %s\n\n' "$description"
  if "$@"; then
    printf '\n  %s\n' "$(_menu_t manage_done)"
  else
    local status=$?
    printf '\n  %s (exit %s)\n' "$(_menu_t manage_failed)" "$status" >&2
  fi
  manage_pause
}

manage_backup_restore() {
  local -a archives=()
  local choice
  shopt -s nullglob
  archives=("$BACKUP_DIR"/server-deployment-*.tar.gz)
  shopt -u nullglob
  if (("${#archives[@]}" == 0)); then
    _menu_warn "$(_menu_t manage_no_backups)"
    manage_pause
    return 0
  fi
  _menu_title "$(_menu_t manage_backup_select)"
  for i in "${!archives[@]}"; do
    printf '  %d. %s\n' "$((i + 1))" "$(basename -- "${archives[$i]}")"
  done
  printf '  0. %s\n\n' "$(_menu_t back)"
  choice="$(installer_menu_read "  $(_menu_t choice): ")" || return 0
  [[ "$choice" =~ ^[0-9]+$ ]] || { _menu_warn "$(_menu_t manage_invalid)"; manage_pause; return 0; }
  (( choice == 0 )) && return 0
  (( choice >= 1 && choice <= ${#archives[@]} )) || { _menu_warn "$(_menu_t manage_invalid)"; manage_pause; return 0; }
  manage_run "$(_menu_t manage_backup_restore)" bash "$ROOT_DIR/modules/07-backup.sh" restore "${archives[$((choice - 1))]}"
}

manage_audit() {
  local role
  _menu_title "$(_menu_t manage_role)"
  printf '  1. VPS A — Entry\n'
  printf '  2. VPS B — Panel + Exit\n'
  printf '  0. %s\n\n' "$(_menu_t back)"
  role="$(installer_menu_read "  $(_menu_t choice) [1/2/0]: ")" || return 0
  case "$role" in
    1) role=A ;;
    2) role=B ;;
    0) return 0 ;;
    *) _menu_warn "$(_menu_t manage_invalid)"; manage_pause; return 0 ;;
  esac
  printf '\n  %s\n' "$(_menu_t manage_audit_warning)"
  manage_run "$(_menu_t manage_audit)" bash "$ROOT_DIR/checks/cascade-audit.sh" "$role"
}

manage_menu() {
  local choice
  while true; do
    _menu_title "$(_menu_t manage_title)" "$(_menu_t manage_select)"
    _menu_show_status
    _menu_section "$(_menu_t manage_title)"
    _menu_option '1.' "$(_menu_t manage_backup_create)"
    _menu_option '2.' "$(_menu_t manage_backup_list)"
    _menu_option '3.' "$(_menu_t manage_backup_restore)"
    _menu_option '4.' "$(_menu_t manage_warp)"
    _menu_option '5.' "$(_menu_t manage_audit)"
    _menu_option '6.' "$(_menu_t manage_bridge)"
    _menu_option '7.' "$(_menu_t manage_validate)"
    printf '\n  ──────────────────────────────────────────────────────\n'
    _menu_option '0.' "$(_menu_t manage_back)"
    printf '\n'
    choice="$(installer_menu_read "  $(_menu_t choice) [1–7/0]: ")" || return 0
    case "$choice" in
      1) manage_run "$(_menu_t manage_backup_create)" bash "$ROOT_DIR/modules/07-backup.sh" create ;;
      2) manage_run "$(_menu_t manage_backup_list)" bash "$ROOT_DIR/modules/07-backup.sh" list ;;
      3) manage_backup_restore ;;
      4) manage_run "$(_menu_t manage_warp)" python3 "$ROOT_DIR/lib/warp_masque.py" menu ;;
      5) manage_audit ;;
      6) manage_run "$(_menu_t manage_bridge)" bash "$ROOT_DIR/install.sh" --configure-bridge ;;
      7) manage_run "$(_menu_t manage_validate)" bash "$ROOT_DIR/install.sh" --check ;;
      0) return 0 ;;
      *) _menu_warn "$(_menu_t manage_invalid)" ;;
    esac
  done
}

manage_menu
