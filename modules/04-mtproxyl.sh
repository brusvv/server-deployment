#!/usr/bin/env bash
set -Eeuo pipefail
source "$SD_ROOT/lib/common.sh"
require_root
cat <<'EOF'
MTProxyL hand-off. Pin and review its installer before execution.
Configure internal loopback listeners first; do not bind public 80/443 until HAProxy is ready.
EOF
if [[ -n "${MTPROXYL_INSTALLER_LOCAL:-}" ]]; then
 [[ "$MTPROXYL_INSTALLER_LOCAL" == /* ]] || die "MTPROXYL_INSTALLER_LOCAL must be an absolute path."
 [[ -f "$MTPROXYL_INSTALLER_LOCAL" && ! -L "$MTPROXYL_INSTALLER_LOCAL" ]] || die "Installer must be a regular, non-symlink file."
 bash -n "$MTPROXYL_INSTALLER_LOCAL" || die "MTProxyL installer failed Bash syntax validation."
 if confirm "Run reviewed local MTProxyL installer?"; then
  [[ -r /dev/tty && -w /dev/tty ]] || die "The local MTProxyL installer requires a controlling TTY; refusing to persist potentially sensitive installer output in logs."
  info "MTProxyL installer output is sent directly to the terminal and is not written to the run log."
  if bash "$MTPROXYL_INSTALLER_LOCAL" > /dev/tty 2>&1; then
   info "MTProxyL installer completed; interactive output was not persisted."
  else
   status=$?
   err "MTProxyL installer failed with exit code $status; review terminal output (not stored in the run log)."
   exit "$status"
  fi
 else
  exit 10
 fi
else
 warn "Set MTPROXYL_INSTALLER_LOCAL to enable this optional hand-off."; exit 10
fi
