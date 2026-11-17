#!/usr/bin/env bash
set -Eeuo pipefail
source "$SD_ROOT/lib/common.sh"
read -r -a remnawave_domains <<< "${REMNAWAVE_SNI_DOMAINS:-}"
for domain in "${remnawave_domains[@]}" "${WEB_DOMAIN:-}"; do
 [[ -n "$domain" ]] || continue
 if getent ahosts "$domain" >/dev/null 2>&1; then
  info "$domain resolves"
 else
  warn "$domain does not resolve"
 fi
done
