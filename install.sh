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
    git clone --depth 1 --branch main "$REPO_URL" "$INSTALL_DIR"
  fi

  exec bash "$INSTALL_DIR/install.sh" "$@"
fi

ROOT_DIR="$SCRIPT_DIR"
export SD_ROOT="$ROOT_DIR"
source "$SD_ROOT/lib/common.sh"
source "$SD_ROOT/lib/config.sh"
MODE=check STAGE=all DRY_RUN=0
usage(){ echo "Usage: sudo ./install.sh [--check|--run] [--dry-run] [--stage preflight|system|remnawave|adapter|mtproxyl|haproxy|validate|backup]"; }
while (($#)); do
 case "$1" in
  --check) MODE=check;; --run) MODE=run;; --dry-run) DRY_RUN=1;;
  --stage) shift; (($#)) || die "--stage needs a value"; STAGE="$1";;
  -h|--help) usage; exit 0;; *) die "Unknown argument: $1";;
 esac; shift
done
export SD_MODE="$MODE" SD_DRY_RUN="$DRY_RUN"
# Export loaded port/service/domain values to child stage processes.
set -a
load_config
set +a
init_logging
run_stage(){ local name="$1" file="$2"; info "===== $name ====="; bash "$ROOT_DIR/modules/$file"; }
if [[ "$STAGE" == all ]]; then
 run_stage preflight 00-preflight.sh
 if [[ "$MODE" == run ]]; then
  run_stage system 01-system.sh; run_stage remnawave 02-remnawave.sh
  run_stage adapter 03-network-adapter.sh; run_stage mtproxyl 04-mtproxyl.sh
  run_stage haproxy 05-haproxy.sh; run_stage validate 06-validation.sh
 fi
else
 case "$STAGE" in
  preflight) run_stage "$STAGE" 00-preflight.sh;; system) run_stage "$STAGE" 01-system.sh;;
  remnawave) run_stage "$STAGE" 02-remnawave.sh;; adapter) run_stage "$STAGE" 03-network-adapter.sh;;
  mtproxyl) run_stage "$STAGE" 04-mtproxyl.sh;; haproxy) run_stage "$STAGE" 05-haproxy.sh;;
  validate) run_stage "$STAGE" 06-validation.sh;; backup) run_stage "$STAGE" 07-backup.sh;;
  *) die "Unknown stage: $STAGE";; esac
fi
