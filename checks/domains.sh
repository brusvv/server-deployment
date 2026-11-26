#!/usr/bin/env bash
set -Eeuo pipefail
source "$SD_ROOT/lib/common.sh"
read -r -a remnawave_domains <<< "${REMNAWAVE_SNI_DOMAINS:-}"
if [[ "${HTTP_REDIRECT_DOMAINS,,}" == "all" ]]; then
 redirect_domains=()
else
 read -r -a redirect_domains <<< "${HTTP_REDIRECT_DOMAINS:-}"
fi
for domain in "${remnawave_domains[@]}" "${WEB_DOMAIN:-}" "${redirect_domains[@]}"; do
 [[ -n "$domain" ]] || continue
 if getent ahosts "$domain" >/dev/null 2>&1; then
  info "$domain resolves"
 else
  warn "$domain does not resolve"
 fi
done
