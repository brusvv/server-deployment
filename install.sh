#!/usr/bin/env bash
set -Eeuo pipefail

# Bootstrap mode: supports both a local checkout and:
#   bash <(curl -fsSL https://raw.githubusercontent.com/brusvv/server-deployment/main/install.sh)
SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
SCRIPT_DIR=""
if [[ -n "$SCRIPT_SOURCE" ]]; then
  SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_SOURCE")" 2>/dev/null && pwd -P)"
fi
REPO_URL="${SD_REPO_URL:-https://github.com/brusvv/server-deployment.git}"
REPO_REF="${SD_GIT_REF:-main}"
INSTALL_DIR="${SD_INSTALL_DIR:-/opt/server-deployment}"

if [[ ! -f "$SCRIPT_DIR/lib/common.sh" ]]; then
  command -v git >/dev/null 2>&1 || {
    echo "ERROR: git is required for remote bootstrap." >&2
    exit 1
  }

  if [[ -e "$INSTALL_DIR" ]]; then
    if [[ -f "$INSTALL_DIR/lib/common.sh" && -d "$INSTALL_DIR/.git" ]]; then
      echo "Using existing checkout: $INSTALL_DIR"
    else
      echo "ERROR: $INSTALL_DIR exists but is not a server-deployment checkout." >&2
      echo "Set SD_INSTALL_DIR to another path or move the existing directory." >&2
      exit 1
    fi
  else
    mkdir -p "$(dirname -- "$INSTALL_DIR")"
    echo "Cloning server-deployment into $INSTALL_DIR ..."
    git clone --depth 1 --branch "$REPO_REF" "$REPO_URL" "$INSTALL_DIR"
  fi

  exec bash "$INSTALL_DIR/install.sh" "$@"
fi

# No-argument interactive launch opens the profile menu. Non-interactive and
# explicit CLI invocations retain the existing check/run behavior.
if (($# == 0)) && [[ -t 0 && -t 1 ]] && [[ -f "$SCRIPT_DIR/installer/main.sh" ]]; then
  exec bash "$SCRIPT_DIR/installer/main.sh"
fi

ROOT_DIR="$SCRIPT_DIR"
export SD_ROOT="$ROOT_DIR"
source "$SD_ROOT/lib/common.sh"
source "$SD_ROOT/lib/config.sh"
MODE=check STAGE=all DRY_RUN=0 CONFIGURE_BRIDGE=0
usage(){ echo "Usage: sudo ./install.sh [--check|--run] [--dry-run] [--configure-bridge] [--stage preflight|system|remnawave|adapter|mtproxyl|haproxy|validate|backup|warp-masque]"; }
persist_bridge_settings(){
 local file="$SD_ROOT/config/ports.env" tmp backup
 [[ -f "$file" && ! -L "$file" ]] || die "Expected a regular config file: $file"
 tmp="$(mktemp "${file}.tmp.XXXXXX")"
 python3 - "$file" "$tmp" "$1" "$2" <<'PY'
import sys
from pathlib import Path
source, target, enabled, port = sys.argv[1:]
lines = Path(source).read_text(encoding="utf-8").splitlines()
out = []
seen_enabled = seen_port = False
for line in lines:
    if line.startswith("SS_BRIDGE_ENABLED="):
        out.append(f'SS_BRIDGE_ENABLED="{enabled}"')
        seen_enabled = True
    elif line.startswith("SS_BRIDGE_PORT="):
        out.append(f'SS_BRIDGE_PORT="{port}"')
        seen_port = True
    else:
        out.append(line)
if not seen_enabled:
    out.append(f'SS_BRIDGE_ENABLED="{enabled}"')
if not seen_port:
    out.append(f'SS_BRIDGE_PORT="{port}"')
Path(target).write_text("\n".join(out) + "\n", encoding="utf-8")
PY
 chmod --reference="$file" "$tmp"
 if cmp -s "$file" "$tmp"; then
  rm -f "$tmp"
  info "Shadowsocks bridge settings are unchanged."
  return 0
 fi
 backup="${file}.before-server-deployment.$(date -u +%Y%m%dT%H%M%SZ).${BASHPID}"
 cp -a "$file" "$backup"
 mv -f -- "$tmp" "$file"
 info "Bridge settings saved; local config backup: $backup"
}
configure_bridge(){
 [[ -t 0 ]] || die "Bridge configuration requires an interactive terminal."
 local current_enabled="${SS_BRIDGE_ENABLED:-0}"
 local current_port="${SS_BRIDGE_PORT:-9999}"
 local enabled answer port_value candidate port_number prompt="[y/N]"
 [[ "$current_enabled" == "1" ]] && prompt="[Y/n]"
 printf '\nShadowsocks bridge setup (VPS A → VPS B)\n'
 printf 'This saves the desired configuration only; it does not create or remove live bridge components.\n'
 read -r -p "Enable the bridge? $prompt " answer
 case "$answer" in
  "") enabled="$current_enabled" ;;
  y|Y|yes|YES) enabled=1 ;;
  n|N|no|NO) enabled=0 ;;
  *) die "Please answer yes or no." ;;
 esac
 port_value="$current_port"
 if [[ "$enabled" == "1" ]]; then
  while true; do
   read -r -p "Bridge port for TCP + UDP [$current_port]: " candidate
   candidate="${candidate:-$current_port}"
   if [[ "$candidate" =~ ^[0-9]{1,5}$ ]]; then
    port_number=$((10#$candidate))
    if (( port_number >= 1 && port_number <= 65535 && port_number != 2222 )); then
     port_value="$port_number"
     break
    fi
   fi
   warn "Enter a numeric port from 1 to 65535, except 2222 (node control port)."
  done
 fi
 persist_bridge_settings "$enabled" "$port_value"
 if [[ "$current_enabled" == "1" && "$enabled" == "1" && "$current_port" != "$port_value" ]]; then
  warn "Port changed in local config only. Teardown the existing Geo Bridge before creating or attaching profiles with the new port; existing inbound/outbound/firewall state was not migrated."
 fi
 if [[ "$current_enabled" == "1" && "$enabled" == "0" ]]; then
  warn "Local config only: existing routes keep running until eGamesAPI Teardown. Teardown removes Entry routes/outbound, service user/squad and recorded UFW rules; then review the leftover SS inbound in B's Config Profile. This wizard does not change live services."
 fi
}
while (($#)); do
 case "$1" in
  --check) MODE=check;; --run) MODE=run;; --dry-run) DRY_RUN=1;; --configure-bridge) CONFIGURE_BRIDGE=1;;
  --stage) shift; (($#)) || die "--stage needs a value"; STAGE="$1";;
  -h|--help) usage; exit 0;; *) die "Unknown argument: $1";;
 esac; shift
done
export SD_MODE="$MODE" SD_DRY_RUN="$DRY_RUN"
# Export loaded port/service/domain values to child stage processes.
set -a
load_config
set +a
if [[ "$CONFIGURE_BRIDGE" == "1" ]]; then
 configure_bridge
 set -a
 load_config
 set +a
 info "Configuration saved. No VPS service, firewall or Remnawave profile was changed."
 exit 0
fi
if [[ "$MODE" == "run" && "$STAGE" == "all" && -t 0 && -t 1 ]]; then
 configure_bridge
 set -a
 load_config
 set +a
fi
init_logging
run_stage(){ local name="$1" file="$2"; info "===== $name ====="; bash "$ROOT_DIR/modules/$file"; }
if [[ "$STAGE" == all ]]; then
 run_stage preflight 00-preflight.sh
 if [[ "$MODE" == run ]]; then
  run_stage system 01-system.sh; run_stage remnawave 02-remnawave.sh
  run_stage adapter 03-network-adapter.sh; run_stage mtproxyl 04-mtproxyl.sh
  run_stage haproxy 05-haproxy.sh; run_stage validate 06-validation.sh; run_stage warp-masque 08-warp-masque.sh
 fi
else
 case "$STAGE" in
  preflight) run_stage "$STAGE" 00-preflight.sh;; system) run_stage "$STAGE" 01-system.sh;;
  remnawave) run_stage "$STAGE" 02-remnawave.sh;; adapter) run_stage "$STAGE" 03-network-adapter.sh;;
  mtproxyl) run_stage "$STAGE" 04-mtproxyl.sh;; haproxy) run_stage "$STAGE" 05-haproxy.sh;;
  validate) run_stage "$STAGE" 06-validation.sh;; backup) run_stage "$STAGE" 07-backup.sh;; warp-masque) run_stage "$STAGE" 08-warp-masque.sh;;
  *) die "Unknown stage: $STAGE";; esac
fi
