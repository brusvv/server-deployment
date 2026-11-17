#!/usr/bin/env bash
set -Eeuo pipefail
source "$SD_ROOT/lib/common.sh"
require_root
printf 'Target Xray inbound: %s:%s\n' "$XRAY_LOOPBACK_HOST" "$XRAY_LOOPBACK_PORT"
printf 'Expected fallback socket: %s\n' "$NGINX_SOCKET"
[[ -S "$NGINX_SOCKET" ]] && info "Fallback socket exists" || warn "Fallback socket not found; eGamesAPI may not be installed yet."
cat <<'EOF'
No Remnawave profile was changed.
Automatic mutation remains disabled until the installed panel's OpenAPI schema,
profile selection, inbound identifier and update payload are pinned and tested.
Implementation must back up the original profile, modify only listen/port, preserve
fallback, apply through the supported API and verify the live listener.
EOF
