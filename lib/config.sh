#!/usr/bin/env bash
set -Eeuo pipefail
load_config(){
 local file
 for file in "$SD_ROOT/config/ports.env" "$SD_ROOT/config/services.env" "$SD_ROOT/config/domains.env"; do
  [[ -f "$file" ]] || { [[ "$file" == */domains.env ]] && continue; die "Missing config: $file"; }
  # shellcheck disable=SC1090
  source "$file"
 done
}
require_domains(){
 : "${PANEL_DOMAIN:?Set PANEL_DOMAIN in config/domains.env}"
 : "${SUBSCRIPTION_DOMAIN:?Set SUBSCRIPTION_DOMAIN in config/domains.env}"
 : "${SELFSTEAL_DOMAIN:?Set SELFSTEAL_DOMAIN in config/domains.env}"
 : "${WEB_DOMAIN:?Set WEB_DOMAIN in config/domains.env}"
}
