#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
export SD_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/port-discovery.sh"

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  [[ "$expected" == "$actual" ]] || { echo "FAIL: $label expected '$expected', got '$actual'" >&2; exit 1; }
}

tmp="$(mktemp)"
tmp_no_xray="$(mktemp)"
tmp_no_xray_patched="$(mktemp)"
tmp_idempotent="$(mktemp)"
tmp_known_http="$(mktemp)"
tmp_known_http_patched="$(mktemp)"
trap 'rm -f "$tmp" "$tmp_no_xray" "$tmp_no_xray_patched" "$tmp_idempotent" "$tmp_known_http" "$tmp_known_http_patched"' EXIT

# Discover the original fixture before any Remnawave or ACME backend exists.
declare -A found=()
while IFS='=' read -r key value; do found["$key"]="$value"; done < <(discover_haproxy_ports "$ROOT/tests/fixtures/haproxy.cfg")
assert_eq 80 "${found[PUBLIC_HTTP_PORT]}" "public HTTP"
assert_eq 443 "${found[PUBLIC_HTTPS_PORT]}" "public HTTPS"
assert_eq 127.0.0.1 "${found[XRAY_LOOPBACK_HOST]}" "Xray host"
assert_eq 1443 "${found[XRAY_LOOPBACK_PORT]}" "Xray port"
assert_eq 15443 "${found[MTPROTO_BACKEND_PORT]}" "MTProto port"
assert_eq 15444 "${found[WEB_TLS_PORT]}" "WEB TLS port"
assert_eq 15080 "${found[WEB_HTTP_PORT]}" "WEB HTTP port"
assert_eq 15481 "${found[SELFSTEAL_BACKEND_PORT]}" "Selfmask backend port"
assert_eq 15481 "${found[STATIC_BACKEND_PORT]}" "MTProxyL static port"
assert_eq 8444 "${found[SELFSTEAL_PORT]}" "Selfmask port"
assert_eq false "${found[ACME_BACKEND_PRESENT]}" "ACME backend absent flag"
assert_eq 127.0.0.1 "${found[ACME_WEBROOT_HOST]}" "default ACME host"
assert_eq 18080 "${found[ACME_WEBROOT_PORT]}" "default ACME port"

# Apply SNI integration, optional HTTP redirects, ACME webroot and backend rename.
python3 "$ROOT/lib/haproxy_config.py" "$ROOT/tests/fixtures/haproxy.cfg" "$tmp" \
  --domains "gateway.example.com sync.example.com" --web-domain "cdn.example.com" \
  --redirect-domains "api.example.com cdn.example.com gateway.example.com sync.example.com" \
  --acme-host 127.0.0.1 --acme-port 18080 \
  --http-port 8080 --https-port 8443 --xray-host 127.0.0.1 --xray-port 2443 \
  --mtproto-host 127.0.0.1 --mtproto-port 25443 \
  --web-tls-host 127.0.0.1 --web-tls-port 25444 \
  --web-http-host 127.0.0.1 --web-http-port 25080 \
  --static-host 127.0.0.1 --static-port 25481 \
  --selfsteal-backend-host 127.0.0.1 --selfsteal-backend-port 25482 --selfsteal-port 9444

grep -Fq 'bind :8080' "$tmp"
grep -Fq 'bind :8443' "$tmp"
grep -Fq 'server remnawave 127.0.0.1:2443' "$tmp"
grep -Fq 'server mtproto 127.0.0.1:25443 send-proxy' "$tmp"
grep -Fq 'server web_tls 127.0.0.1:25444 send-proxy' "$tmp"
grep -Fq 'bind 127.0.0.1:25444 accept-proxy' "$tmp"
grep -Fq 'server web 127.0.0.1:25080' "$tmp"
grep -Fq 'server site 127.0.0.1:25482' "$tmp"
grep -Fq 'server static 127.0.0.1:25481' "$tmp"
grep -Fq 'bind 127.0.0.1:9444' "$tmp"
grep -Fq 'acl remnawave_sni req.ssl_sni -i gateway.example.com sync.example.com' "$tmp"
grep -Fq 'acl acme path_beg /.well-known/acme-challenge/' "$tmp"
grep -Fq 'acl sd_http_redirect_hosts hdr(host),field(1,:) -i api.example.com cdn.example.com gateway.example.com sync.example.com' "$tmp"
grep -Fq 'http-request deny deny_status 404 unless sd_http_redirect_hosts' "$tmp"
grep -Fq 'http-request redirect scheme https code 301 if sd_http_redirect_hosts !acme' "$tmp"
grep -Fq 'use_backend mtproxyl_acme if acme' "$tmp"

# The special value "all" redirects every HTTP request except ACME challenges.
tmp_all="$(mktemp)"
python3 "$ROOT/lib/haproxy_config.py" "$ROOT/tests/fixtures/haproxy.cfg" "$tmp_all" \
  --domains "gateway.example.com sync.example.com" --web-domain "cdn.example.com" \
  --redirect-domains "all" \
  --acme-host 127.0.0.1 --acme-port 18080 \
  --http-port 80 --https-port 443 --xray-host 127.0.0.1 --xray-port 1443 \
  --mtproto-host 127.0.0.1 --mtproto-port 15443 \
  --web-tls-host 127.0.0.1 --web-tls-port 15444 \
  --web-http-host 127.0.0.1 --web-http-port 15080 \
  --static-host 127.0.0.1 --static-port 15481 \
  --selfsteal-backend-host 127.0.0.1 --selfsteal-backend-port 15482 --selfsteal-port 8444
grep -Fq 'http-request redirect scheme https code 301 if !acme' "$tmp_all"
grep -Fq 'use_backend mtproxyl_acme if acme' "$tmp_all"
if grep -Fq 'sd_http_redirect_hosts' "$tmp_all"; then
  echo "Catch-all redirect unexpectedly generated a hostname allowlist" >&2
  exit 1
fi
if grep -Fq 'http-request deny deny_status 404 unless' "$tmp_all"; then
  echo "Catch-all redirect unexpectedly generated a Host deny rule" >&2
  exit 1
fi
rm -f "$tmp_all"
grep -Fq 'backend mtproxyl_acme' "$tmp"
grep -Fq 'server acme 127.0.0.1:18080' "$tmp"
grep -Fq 'default_backend mtproxyl_web_backend' "$tmp"
grep -Eq '^backend mtproxyl_web_backend$' "$tmp"
if grep -Eq '^backend mtproxyl_web$' "$tmp"; then
  echo "FAIL: legacy WEB backend name was not renamed" >&2
  exit 1
fi

# Reproduce the known_http_host ACL variant that was manually deployed on the VPS.
python3 - "$ROOT/tests/fixtures/haproxy.cfg" "$tmp_known_http" <<'PY'
from pathlib import Path
import sys

source, target = map(Path, sys.argv[1:])
text = source.read_text()
marker = "    default_backend mtproxyl_static\n"
legacy_rules = """    acl acme path_beg /.well-known/acme-challenge/
    acl known_http_host hdr(host),field(1,:) -i api.example.com cdn.example.com gateway.example.com sync.example.com storage.example.com
    http-request deny deny_status 404 unless known_http_host
    http-request redirect scheme https code 301 if known_http_host !acme
    use_backend mtproxyl_acme if acme
"""
if text.count(marker) != 1:
    raise SystemExit("fixture HTTP frontend marker is not unique")
target.write_text(text.replace(marker, legacy_rules + marker, 1))
PY

python3 "$ROOT/lib/haproxy_config.py" "$tmp_known_http" "$tmp_known_http_patched" \
  --domains "gateway.example.com sync.example.com" --web-domain "cdn.example.com" \
  --redirect-domains "api.example.com cdn.example.com gateway.example.com sync.example.com" \
  --acme-host 127.0.0.1 --acme-port 18080 \
  --http-port 80 --https-port 443 --xray-host 127.0.0.1 --xray-port 1443 \
  --mtproto-host 127.0.0.1 --mtproto-port 15443 \
  --web-tls-host 127.0.0.1 --web-tls-port 15444 \
  --web-http-host 127.0.0.1 --web-http-port 15080 \
  --static-host 127.0.0.1 --static-port 15481 \
  --selfsteal-backend-host 127.0.0.1 --selfsteal-backend-port 15481 --selfsteal-port 8444
if grep -Fq "known_http_host" "$tmp_known_http_patched"; then
  echo "FAIL: manually deployed known_http_host rules were not replaced" >&2
  exit 1
fi
[[ "$(grep -Fc 'acl sd_http_redirect_hosts ' "$tmp_known_http_patched")" == 1 ]]
[[ "$(grep -Fc 'use_backend mtproxyl_acme if acme' "$tmp_known_http_patched")" == 1 ]]

# Discovery must recognize the renamed WEB backend and the new ACME backend.
declare -A patched=()
while IFS='=' read -r key value; do patched["$key"]="$value"; done < <(discover_haproxy_ports "$tmp")
assert_eq true "${patched[ACME_BACKEND_PRESENT]}" "ACME backend present flag"
assert_eq 127.0.0.1 "${patched[ACME_WEBROOT_HOST]}" "discovered ACME host"
assert_eq 18080 "${patched[ACME_WEBROOT_PORT]}" "discovered ACME port"
assert_eq 25080 "${patched[WEB_HTTP_PORT]}" "WEB listener after backend rename"

# Initial MTProxyL config may not have Remnawave installed yet.
sed '/^backend remnawave_xray$/,$d' "$ROOT/tests/fixtures/haproxy.cfg" > "$tmp_no_xray"
declare -A initial=()
while IFS='=' read -r key value; do initial["$key"]="$value"; done < <(discover_haproxy_ports "$tmp_no_xray")
assert_eq false "${initial[XRAY_BACKEND_PRESENT]}" "Xray backend absent flag"
assert_eq 127.0.0.1 "${initial[XRAY_LOOPBACK_HOST]}" "default Xray host without backend"
assert_eq 1443 "${initial[XRAY_LOOPBACK_PORT]}" "default Xray port without backend"

python3 "$ROOT/lib/haproxy_config.py" "$tmp_no_xray" "$tmp_no_xray_patched" \
  --domains "gateway.example.com sync.example.com" --web-domain "cdn.example.com" \
  --redirect-domains "api.example.com cdn.example.com gateway.example.com sync.example.com" \
  --acme-host 127.0.0.1 --acme-port 18080 \
  --http-port 80 --https-port 443 --xray-host 127.0.0.1 --xray-port 1443 \
  --mtproto-host 127.0.0.1 --mtproto-port 15443 \
  --web-tls-host 127.0.0.1 --web-tls-port 15444 \
  --web-http-host 127.0.0.1 --web-http-port 15080 \
  --static-host 127.0.0.1 --static-port 15481 \
  --selfsteal-backend-host 127.0.0.1 --selfsteal-backend-port 15481 --selfsteal-port 8444
grep -Fq 'backend remnawave_xray' "$tmp_no_xray_patched"
grep -Fq 'server remnawave 127.0.0.1:1443' "$tmp_no_xray_patched"
grep -Fq 'use_backend remnawave_xray if remnawave_sni' "$tmp_no_xray_patched"
grep -Fq 'server acme 127.0.0.1:18080' "$tmp_no_xray_patched"

# Re-running the patcher with the same inputs must not duplicate rules or backends.
python3 "$ROOT/lib/haproxy_config.py" "$tmp" "$tmp_idempotent" \
  --domains "gateway.example.com sync.example.com" --web-domain "cdn.example.com" \
  --redirect-domains "api.example.com cdn.example.com gateway.example.com sync.example.com" \
  --acme-host 127.0.0.1 --acme-port 18080 \
  --http-port 8080 --https-port 8443 --xray-host 127.0.0.1 --xray-port 2443 \
  --mtproto-host 127.0.0.1 --mtproto-port 25443 \
  --web-tls-host 127.0.0.1 --web-tls-port 25444 \
  --web-http-host 127.0.0.1 --web-http-port 25080 \
  --static-host 127.0.0.1 --static-port 25481 \
  --selfsteal-backend-host 127.0.0.1 --selfsteal-backend-port 25482 --selfsteal-port 9444
diff -u "$tmp" "$tmp_idempotent"

echo "HAProxy discovery and config patch tests passed."
