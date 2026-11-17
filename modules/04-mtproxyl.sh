#!/usr/bin/env bash
set -Eeuo pipefail
source "$SD_ROOT/lib/common.sh"
require_root
cat <<'EOF'
MTProxyL hand-off. Pin and review its installer before execution.
Configure internal loopback listeners first; do not bind public 80/443 until HAProxy is ready.
EOF
if [[ -n "${MTPROXYL_INSTALLER_LOCAL:-}" ]]; then
 [[ -f "$MTPROXYL_INSTALLER_LOCAL" ]] || die "Installer file not found"
 if confirm "Run reviewed local MTProxyL installer?"; then bash "$MTPROXYL_INSTALLER_LOCAL"; fi
else
 warn "Set MTPROXYL_INSTALLER_LOCAL to enable this hand-off."
fi
