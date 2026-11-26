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
printf 'Required Xray bind before HAProxy: %s:%s\n' "$XRAY_LOOPBACK_HOST" "$XRAY_LOOPBACK_PORT"
if [[ -S "$NGINX_SOCKET" ]]; then
 info "Fallback socket exists"
else
 warn "Fallback socket not found; eGamesAPI may not be installed yet."
fi
cat <<'EOF'
HAProxy must own public TCP/443. Do not leave the Xray inbound bound to 0.0.0.0:443.
In the selected Remnawave Config Profile, set the Xray inbound to 127.0.0.1:1443
(or the configured XRAY_LOOPBACK_HOST:XRAY_LOOPBACK_PORT) and preserve the fallback.
The HAProxy stage now requires a live listener on that exact loopback endpoint.

No Remnawave profile was changed.
Automatic mutation remains disabled until the installed panel's OpenAPI schema,
profile selection, inbound identifier and update payload are pinned and tested.
Configure the selected listen address/port in the Remnawave profile, preserve
the fallback, then rerun the HAProxy stage to verify the live listener.
EOF
