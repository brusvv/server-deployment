#!/usr/bin/env bash
set -Eeuo pipefail
source "$SD_ROOT/lib/common.sh"

for port in "$PUBLIC_HTTP_PORT" "$PUBLIC_HTTPS_PORT"; do
 if ss -H -lnt "( sport = :$port )" 2>/dev/null | grep -q .; then
  warn "TCP $port is occupied"
  ss -lntp "( sport = :$port )" || true
 else
  info "TCP $port is free"
 fi
done

# The optional bridge listener is checked only when explicitly enabled.
# Check TCP and UDP independently; the bridge needs both transports.
if [[ "${SS_BRIDGE_ENABLED:-0}" == "1" ]]; then
 if ss -H -lnt "( sport = :$SS_BRIDGE_PORT )" 2>/dev/null | grep -q .; then
  warn "TCP $SS_BRIDGE_PORT is occupied; inspect before enabling the bridge"
  ss -lntp "( sport = :$SS_BRIDGE_PORT )" || true
 else
  info "TCP $SS_BRIDGE_PORT is free"
 fi
 if ss -H -lnu "( sport = :$SS_BRIDGE_PORT )" 2>/dev/null | grep -q .; then
  warn "UDP $SS_BRIDGE_PORT is occupied; inspect before enabling the bridge"
  ss -lnup "( sport = :$SS_BRIDGE_PORT )" || true
 else
  info "UDP $SS_BRIDGE_PORT is free"
 fi
else
 info "Shadowsocks bridge disabled; skip bridge listener port checks."
fi
