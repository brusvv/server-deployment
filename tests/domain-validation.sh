#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

run_validation() {
  local sni="$1" web="$2" redirects="$3" allow_all="${4:-0}"
  SD_ROOT="$ROOT" SNI="$sni" WEB="$web" REDIRECTS="$redirects" ALLOW_ALL="$allow_all" bash -c '
    set -Eeuo pipefail
    source "$SD_ROOT/lib/common.sh"
    source "$SD_ROOT/lib/domain-validation.sh"
    validate_domain_list "Remnawave SNI/WEB" "$SNI $WEB"
    validate_domain_list "HTTP redirect allowlist" "$REDIRECTS" "$ALLOW_ALL"
  '
}

run_validation "edge.example.com" "web.example.net" "edge.example.com web.example.net redirect.example.org"
run_validation "edge.example.com" "web.example.net" "all" 1

if run_validation "edge.example.com EDGE.EXAMPLE.COM" "web.example.net" ""; then
  echo "Case-insensitive duplicate in SNI list unexpectedly passed" >&2
  exit 1
fi
if run_validation "edge.example.com" "EDGE.EXAMPLE.COM" ""; then
  echo "Case-insensitive duplicate between SNI and WEB unexpectedly passed" >&2
  exit 1
fi
if run_validation "edge.example.com" "web.example.net" "redirect.example.org REDIRECT.EXAMPLE.ORG"; then
  echo "Case-insensitive duplicate in redirect allowlist unexpectedly passed" >&2
  exit 1
fi
if run_validation "edge..example.com" "web.example.net" ""; then
  echo "Malformed domain unexpectedly passed" >&2
  exit 1
fi
if run_validation "edge.example.com" "web.example.net" "https://redirect.example.org"; then
  echo "URL rather than hostname unexpectedly passed" >&2
  exit 1
fi
if run_validation "all" "web.example.net" ""; then
  echo "'all' unexpectedly passed as a Remnawave SNI hostname" >&2
  exit 1
fi
if run_validation "edge.example.com" "web.example.net" "all redirect.example.org" 1; then
  echo "'all' mixed with hostnames unexpectedly passed" >&2
  exit 1
fi

echo "Domain syntax and duplicate validation tests passed."
