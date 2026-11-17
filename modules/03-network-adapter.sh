#!/usr/bin/env bash
set -Eeuo pipefail
source "$SD_ROOT/lib/common.sh"
source "$SD_ROOT/lib/config.sh"
load_config
source "$SD_ROOT/lib/port-discovery.sh"
require_root

if [[ -f "$SD_PORT_PLAN_FILE" && ! -L "$SD_PORT_PLAN_FILE" ]]; then
 load_port_plan
 info "Using the pending HAProxy port plan as the Xray target."
fi

printf 'Target Xray inbound: %s:%s\n' "$XRAY_LOOPBACK_HOST" "$XRAY_LOOPBACK_PORT"
printf 'Expected fallback socket: %s\n' "$NGINX_SOCKET"
[[ -S "$NGINX_SOCKET" ]] && info "Fallback socket exists" || warn "Fallback socket not found; eGamesAPI may not be installed yet."
cat <<'EOF'
No Remnawave profile was changed.
Automatic mutation remains disabled until the installed panel's OpenAPI schema,
profile selection, inbound identifier and update payload are pinned and tested.
Configure the selected listen address/port in the Remnawave profile, preserve
the fallback, then rerun the HAProxy stage to verify the live listener.
EOF
