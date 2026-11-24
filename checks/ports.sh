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

# The bridge port is expected to be unused before the SS inbound is deployed.
# Check TCP and UDP independently; the bridge will need both transports.
if [[ -n "${SS_BRIDGE_PORT:-}" ]]; then
 for transport in tcp udp; do
  case "$transport" in
   tcp) socket_filter="-lnt" ;;
   udp) socket_filter="-lnu" ;;
  esac
  if ss -H $socket_filter "( sport = :$SS_BRIDGE_PORT )" 2>/dev/null | grep -q .; then
   warn "$transport $SS_BRIDGE_PORT is occupied; inspect before enabling the bridge"
   ss "$socket_filter" -p "( sport = :$SS_BRIDGE_PORT )" || true
  else
   info "$transport $SS_BRIDGE_PORT is free"
  fi
 done
fi
