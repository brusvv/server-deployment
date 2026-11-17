#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
export SD_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/port-discovery.sh"

declare -A found=()
while IFS='=' read -r key value; do found["$key"]="$value"; done < <(discover_haproxy_ports "$ROOT/tests/fixtures/haproxy.cfg")

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  [[ "$expected" == "$actual" ]] || { echo "FAIL: $label expected '$expected', got '$actual'" >&2; exit 1; }
}
assert_eq 80 "${found[PUBLIC_HTTP_PORT]}" "public HTTP"
assert_eq 443 "${found[PUBLIC_HTTPS_PORT]}" "public HTTPS"
assert_eq 127.0.0.1 "${found[XRAY_LOOPBACK_HOST]}" "Xray host"
assert_eq 1443 "${found[XRAY_LOOPBACK_PORT]}" "Xray port"
assert_eq 15443 "${found[MTPROTO_BACKEND_PORT]}" "MTProto port"
assert_eq 15444 "${found[WEB_TLS_PORT]}" "WEB TLS port"
assert_eq 15080 "${found[WEB_HTTP_PORT]}" "WEB HTTP port"
assert_eq 8444 "${found[SELFSTEAL_PORT]}" "Selfmask port"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
python3 "$ROOT/lib/haproxy_config.py" "$ROOT/tests/fixtures/haproxy.cfg" "$tmp" \
  --domains "gateway.example.com sync.example.com" --web-domain "cdn.example.com" \
  --http-port 8080 --https-port 8443 --xray-host 127.0.0.1 --xray-port 2443 \
  --mtproto-host 127.0.0.1 --mtproto-port 25443 \
  --web-tls-host 127.0.0.1 --web-tls-port 25444 \
  --web-http-host 127.0.0.1 --web-http-port 25080 --selfsteal-port 9444

grep -Fq 'bind :8080' "$tmp"
grep -Fq 'bind :8443' "$tmp"
grep -Fq 'server remnawave 127.0.0.1:2443' "$tmp"
grep -Fq 'server mtproto 127.0.0.1:25443 send-proxy' "$tmp"
grep -Fq 'server web_tls 127.0.0.1:25444 send-proxy' "$tmp"
grep -Fq 'server web 127.0.0.1:25080' "$tmp"
grep -Fq 'bind 127.0.0.1:9444' "$tmp"
grep -Fq 'acl remnawave_sni req.ssl_sni -i gateway.example.com sync.example.com' "$tmp"

echo "HAProxy discovery and config patch tests passed."
