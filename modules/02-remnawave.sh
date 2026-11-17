#!/usr/bin/env bash
set -Eeuo pipefail
source "$SD_ROOT/lib/common.sh"
require_root
cat <<'EOF'
eGamesAPI is the installer entry point; its installation flow installs/configures Remnawave.
Do not install a second independent Remnawave stack here.
Pin and review the upstream installer before execution. Confirm public TCP 80/443 are available.
This scaffold executes only a local reviewed copy supplied via EGAMES_INSTALLER_LOCAL.
EOF
if [[ -n "${EGAMES_INSTALLER_LOCAL:-}" ]]; then
 [[ -f "$EGAMES_INSTALLER_LOCAL" ]] || die "Installer file not found"
 if confirm "Run reviewed local eGamesAPI installer?"; then bash "$EGAMES_INSTALLER_LOCAL"; fi
else
 warn "Set EGAMES_INSTALLER_LOCAL to enable this hand-off."
fi
