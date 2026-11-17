#!/usr/bin/env bash
set -Eeuo pipefail
source "$SD_ROOT/lib/common.sh"
read -r -a remnawave_domains <<< "${REMNAWAVE_SNI_DOMAINS:-}"
for domain in "${remnawave_domains[@]}" "${WEB_DOMAIN:-}"; do
 [[ -n "$domain" ]] || continue
 getent ahosts "$domain" >/dev/null 2>&1 && info "$domain resolves" || warn "$domain does not resolve"
done
