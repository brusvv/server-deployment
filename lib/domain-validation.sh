#!/usr/bin/env bash
# Validate whitespace-separated DNS hostnames and reject case-insensitive duplicates.
validate_domain_list() {
  local label="$1" raw="$2" domain normalized
  local -a domains=()
  local -A seen=()
  read -r -a domains <<< "$raw"
  for domain in "${domains[@]}"; do
    [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]] ||
      die "Invalid domain in $label: $domain"
    normalized="${domain,,}"
    [[ -z "${seen[$normalized]:-}" ]] || die "Duplicate domain in $label (DNS names are case-insensitive): $domain"
    seen["$normalized"]=1
  done
}
