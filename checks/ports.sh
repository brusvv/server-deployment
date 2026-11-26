#!/usr/bin/env bash
set -Eeuo pipefail
source "$SD_ROOT/lib/common.sh"
if ! command -v ss >/dev/null 2>&1; then
 warn "ss (iproute2) is unavailable; port occupancy checks are skipped, not assumed free. The System stage installs iproute2; rerun validation afterward."
 exit 0
fi

validate_port_value() {
 local name="$1" value="$2" number
 [[ "$value" =~ ^[0-9]{1,5}$ ]] || die "$name must be a numeric TCP/UDP port from 1 to 65535; got '$value'."
 number=$((10#$value))
 (( number >= 1 && number <= 65535 )) || die "$name is outside the valid port range 1-65535."
 printf '%s' "$number"
}

PUBLIC_HTTP_PORT="$(validate_port_value PUBLIC_HTTP_PORT "${PUBLIC_HTTP_PORT:-}")"
PUBLIC_HTTPS_PORT="$(validate_port_value PUBLIC_HTTPS_PORT "${PUBLIC_HTTPS_PORT:-}")"
[[ "$PUBLIC_HTTP_PORT" != "$PUBLIC_HTTPS_PORT" ]] || die "PUBLIC_HTTP_PORT and PUBLIC_HTTPS_PORT must be different."

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
 SS_BRIDGE_PORT="$(validate_port_value SS_BRIDGE_PORT "${SS_BRIDGE_PORT:-}")"
 [[ "$SS_BRIDGE_PORT" != "$PUBLIC_HTTP_PORT" && "$SS_BRIDGE_PORT" != "$PUBLIC_HTTPS_PORT" ]] ||
  die "SS_BRIDGE_PORT must not overlap the public HTTP/HTTPS ports."
 if ss -H -lnt "( sport = :$SS_BRIDGE_PORT )" 2>/dev/null | grep -q .; then
  ss -lntp "( sport = :$SS_BRIDGE_PORT )" || true
  die "TCP $SS_BRIDGE_PORT is occupied; choose another SS_BRIDGE_PORT"
 else
  info "TCP $SS_BRIDGE_PORT is free"
 fi
 if ss -H -lnu "( sport = :$SS_BRIDGE_PORT )" 2>/dev/null | grep -q .; then
  ss -lnup "( sport = :$SS_BRIDGE_PORT )" || true
  die "UDP $SS_BRIDGE_PORT is occupied; choose another SS_BRIDGE_PORT"
 else
  info "UDP $SS_BRIDGE_PORT is free"
 fi
else
 info "Shadowsocks bridge disabled; skip bridge listener port checks."
fi
