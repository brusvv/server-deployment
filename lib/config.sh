#!/usr/bin/env bash
set -Eeuo pipefail
load_config(){
 local file
 for file in "$SD_ROOT/config/ports.env" "$SD_ROOT/config/services.env" "$SD_ROOT/config/domains.env"; do
  [[ -f "$file" ]] || { [[ "$file" == */domains.env ]] && continue; die "Missing config: $file"; }
  # shellcheck disable=SC1090
  source "$file"
 done
 # Backward compatibility for existing domains.env files.
 if [[ -z "${REMNAWAVE_SNI_DOMAINS:-}" ]]; then
  REMNAWAVE_SNI_DOMAINS="${PANEL_DOMAIN:-} ${SUBSCRIPTION_DOMAIN:-} ${SELFSTEAL_DOMAIN:-} ${REMNAWAVE_EXTRA_DOMAINS:-}"
 fi
}
require_domains(){
 [[ -n "${REMNAWAVE_SNI_DOMAINS//[[:space:]]/}" ]] || die "Set REMNAWAVE_SNI_DOMAINS in config/domains.env"
 : "${WEB_DOMAIN:?Set WEB_DOMAIN in config/domains.env}"
}
