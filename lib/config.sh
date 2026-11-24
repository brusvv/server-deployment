#!/usr/bin/env bash
set -Eeuo pipefail
load_config(){
 local file allexport_was_enabled=0
 case "$-" in *a*) allexport_was_enabled=1;; esac
 set -a
 for file in "$SD_ROOT/config/ports.env" "$SD_ROOT/config/services.env" "$SD_ROOT/config/domains.env"; do
  [[ -f "$file" ]] || { [[ "$file" == */domains.env ]] && continue; die "Missing config: $file"; }
  # shellcheck disable=SC1090
  source "$file"
 done
 # Backward compatibility for existing domains.env files.
 if [[ -z "${REMNAWAVE_SNI_DOMAINS:-}" ]]; then
  REMNAWAVE_SNI_DOMAINS="${PANEL_DOMAIN:-} ${SUBSCRIPTION_DOMAIN:-} ${SELFSTEAL_DOMAIN:-} ${REMNAWAVE_EXTRA_DOMAINS:-}"
 fi
 # HTTP redirects are opt-in to preserve the existing strict behavior.
 HTTP_REDIRECT_DOMAINS="${HTTP_REDIRECT_DOMAINS:-}"
 ACME_WEBROOT_HOST="${ACME_WEBROOT_HOST:-127.0.0.1}"
 ACME_WEBROOT_PORT="${ACME_WEBROOT_PORT:-18080}"
 XRAY_LISTENER_REQUIRED="${XRAY_LISTENER_REQUIRED:-0}"
 # The cascade bridge is opt-in. Validate its saved settings even when disabled.
 SS_BRIDGE_ENABLED="${SS_BRIDGE_ENABLED:-0}"
 SS_BRIDGE_PORT="${SS_BRIDGE_PORT:-9999}"
 SS_BRIDGE_BIND="${SS_BRIDGE_BIND:-0.0.0.0}"
 SS_BRIDGE_NETWORK="${SS_BRIDGE_NETWORK:-tcp,udp}"
 SS_BRIDGE_METHOD="${SS_BRIDGE_METHOD:-chacha20-ietf-poly1305}"
 case "$SS_BRIDGE_ENABLED" in
  0|1) ;;
  *) die "SS_BRIDGE_ENABLED must be 0 (disabled) or 1 (enabled)" ;;
 esac
 [[ "$SS_BRIDGE_PORT" =~ ^[0-9]{1,5}$ ]] || die "SS_BRIDGE_PORT must be an integer from 1 to 65535"
 local bridge_port_number
 bridge_port_number=$((10#$SS_BRIDGE_PORT))
 (( bridge_port_number >= 1 && bridge_port_number <= 65535 && bridge_port_number != 2222 )) || die "SS_BRIDGE_PORT must be from 1 to 65535, except 2222 (node control port)"
 SS_BRIDGE_PORT="$bridge_port_number"
 if (( allexport_was_enabled == 0 )); then set +a; fi
}
require_domains(){
 [[ -n "${REMNAWAVE_SNI_DOMAINS//[[:space:]]/}" ]] || die "Set REMNAWAVE_SNI_DOMAINS in config/domains.env"
 : "${WEB_DOMAIN:?Set WEB_DOMAIN in config/domains.env}"
}
