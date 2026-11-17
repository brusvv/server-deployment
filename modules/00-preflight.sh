#!/usr/bin/env bash
set -Eeuo pipefail
source "$SD_ROOT/lib/common.sh"
source "$SD_ROOT/lib/config.sh"
[[ -r /etc/os-release ]] || die "Cannot identify OS"
. /etc/os-release
[[ "${ID:-}" == debian || "${ID:-}" == ubuntu ]] || die "Supported OS: Debian/Ubuntu; found ${ID:-unknown}"
require_domains
read -r -a remnawave_domains <<< "$REMNAWAVE_SNI_DOMAINS"
declare -A seen_domains=()
for domain in "${remnawave_domains[@]}" "$WEB_DOMAIN"; do
 [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]] || die "Invalid domain: $domain"
 [[ -z "${seen_domains[$domain]:-}" ]] || die "Duplicate domain: $domain"
 seen_domains["$domain"]=1
done
"$SD_ROOT/checks/domains.sh"
"$SD_ROOT/checks/ports.sh"
info "Preflight completed"
