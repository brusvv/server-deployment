#!/usr/bin/env bash
# Read-only inventory for the Remnawave A<->B cascade.
# This script deliberately avoids reading .env files, service environments,
# Docker inspect output, private keys, certificates, or process command lines.
set -Eeuo pipefail

ROLE="${1:-}"
case "$ROLE" in
  A|B) ;;
  *) echo "Usage: sudo bash checks/cascade-audit.sh A|B" >&2; exit 2 ;;
esac

section() { printf '\n===== %s =====\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

section "Audit metadata"
printf 'Role label: VPS %s\n' "$ROLE"
printf 'Timestamp: %s\n' "$(date -Is 2>/dev/null || date)"
printf 'Hostname: %s\n' "$(hostname -f 2>/dev/null || hostname)"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  printf 'OS: %s %s (%s)\n' "${PRETTY_NAME:-unknown}" "${VERSION_ID:-}" "${ID:-}"
fi
printf 'Kernel: %s\n' "$(uname -r)"
printf 'CPU: %s vCPU(s)\n' "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo unknown)"
free -h 2>/dev/null || true
df -h / 2>/dev/null || true

section "Interfaces and routes"
if have ip; then
  ip -br address 2>/dev/null || true
  echo "-- routes --"
  ip route 2>/dev/null || true
  ip -6 route 2>/dev/null || true
else
  echo "ip command unavailable"
fi

section "Listening sockets"
if have ss; then
  # No process arguments are printed, only listener address/port and process name/PID.
  ss -lntup 2>/dev/null || ss -lnt 2>/dev/null || true
else
  echo "ss command unavailable"
fi

section "Relevant systemd services"
if have systemctl; then
  systemctl list-units --type=service --all --no-legend 2>/dev/null \
    | grep -Ei 'haproxy|mtproxy|telemt|xray|remna|nginx|docker|containerd|certbot' \
    || echo "No matching systemd units listed"
else
  echo "systemctl unavailable"
fi

section "Docker inventory (names/images/status/ports only)"
if have docker; then
  docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null \
    || echo "Docker query unavailable"
  echo "-- compose projects --"
  docker compose ls 2>/dev/null || true
else
  echo "Docker not installed"
fi

section "Firewall status"
if have ufw; then
  ufw status verbose 2>/dev/null || true
else
  echo "UFW not installed"
fi
if have nft; then
  echo "-- nftables ruleset (read-only) --"
  nft list ruleset 2>/dev/null || echo "nftables ruleset unavailable"
elif have iptables; then
  echo "-- iptables rules (read-only) --"
  iptables -S 2>/dev/null || true
fi

section "Cascade-specific reference ports"
case "$ROLE" in
  A)
    cat <<'INFO'
VPS A is expected to be the client Entry Node.
Inspect actual XHTTP listener(s) and the Remnawave Node control listener.
The Panel on B must be able to reach A's configured Node control port
(default 2222/tcp in the eGamesAPI bridge helper; verify the real value).
A should not expose the B-side Shadowsocks inbound port.
INFO
    ;;
  B)
    cat <<'INFO'
VPS B is expected to host Panel + Exit Node.
Reference public web ingress: 80/tcp and 443/tcp (HAProxy).
Optional bridge listener: use SS_BRIDGE_ENABLED and SS_BRIDGE_PORT from config/ports.env (default disabled; port 9999/tcp+udp).
Historical MTProto backend: 127.0.0.1:15443/tcp (verify current Telemt/HAProxy config).
Panel -> local Node control traffic should remain internal where possible.
INFO
    section "Remnawave Nginx fingerprint (read-only)"
    nginx_conf="/opt/remnawave/nginx.conf"
    if [[ -f "$nginx_conf" ]]; then
      if grep -Eq '^[[:space:]]*server_tokens[[:space:]]+off;' "$nginx_conf"; then
        echo "PASS: server_tokens off is present in /opt/remnawave/nginx.conf"
      else
        echo "WARN: server_tokens off is missing from /opt/remnawave/nginx.conf"
      fi
    else
      echo "WARN: /opt/remnawave/nginx.conf not found; confirm actual eGamesAPI install path"
    fi
    if have docker && docker container inspect remnawave-nginx >/dev/null 2>&1; then
      docker exec remnawave-nginx nginx -t 2>&1 || echo "FAIL: remnawave-nginx config test failed"
    else
      echo "WARN: remnawave-nginx container is not present"
    fi
    cat <<'HEADERS'
Subscription response-header review (manual, Panel B):
- Settings -> Subscription Settings -> Custom Response Headers
- Remove support-url if it points to https://dummy.docs.rw
- Keep the profile-title key; change its VALUE to the intended brand
- Inspect profile-web-page-url and all other custom headers for demo domains
- Check subscription-page brandingSettings.supportUrl separately
Do not put subscription UUIDs or full subscription URLs in audit output.
HEADERS
    ;;
esac

section "Safety"
cat <<'INFO'
This audit is read-only. It does not restart services, change firewall rules,
read secrets, inspect container environment variables, or modify Xray/HAProxy.
The output may contain public/private IP addresses, hostnames, and firewall
source addresses. Review/redact those before sharing it outside your team.
INFO
