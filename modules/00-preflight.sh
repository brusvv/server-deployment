#!/usr/bin/env bash
set -Eeuo pipefail
source "$SD_ROOT/lib/common.sh"
source "$SD_ROOT/lib/config.sh"
source "$SD_ROOT/lib/domain-validation.sh"
[[ -r /etc/os-release ]] || die "Cannot identify OS"
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == debian || "${ID:-}" == ubuntu ]] || die "Supported OS: Debian/Ubuntu; found ${ID:-unknown}"
require_domains
validate_domain_list "Remnawave SNI/WEB" "$REMNAWAVE_SNI_DOMAINS $WEB_DOMAIN"
validate_domain_list "HTTP redirect allowlist" "$HTTP_REDIRECT_DOMAINS" 1
bash "$SD_ROOT/checks/domains.sh"
bash "$SD_ROOT/checks/ports.sh"
info "Preflight completed"
