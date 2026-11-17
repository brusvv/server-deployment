#!/usr/bin/env bash
set -Eeuo pipefail
source "$SD_ROOT/lib/common.sh"
for key in PANEL_DOMAIN SUBSCRIPTION_DOMAIN SELFSTEAL_DOMAIN WEB_DOMAIN; do
 domain="${!key:-}"
 [[ -n "$domain" ]] || { warn "$key is not configured"; continue; }
 getent ahosts "$domain" >/dev/null 2>&1 && info "$domain resolves" || warn "$domain does not resolve"
done
