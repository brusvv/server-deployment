#!/usr/bin/env bash
set -Eeuo pipefail
source "$SD_ROOT/lib/common.sh"
for port in "$PUBLIC_HTTP_PORT" "$PUBLIC_HTTPS_PORT"; do
 if ss -H -lnt "( sport = :$port )" 2>/dev/null | grep -q .; then
  warn "TCP $port is occupied"
  ss -lntp "( sport = :$port )" || true
 else info "TCP $port is free"; fi
done
