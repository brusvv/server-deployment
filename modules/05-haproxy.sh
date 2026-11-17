#!/usr/bin/env bash
set -Eeuo pipefail
source "$SD_ROOT/lib/common.sh"
source "$SD_ROOT/lib/config.sh"
require_root
require_domains
output="${HAPROXY_RENDERED_CONFIG:-$STATE_DIR/haproxy.cfg}"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
export PANEL_DOMAIN SUBSCRIPTION_DOMAIN SELFSTEAL_DOMAIN WEB_DOMAIN
export XRAY_LOOPBACK_HOST XRAY_LOOPBACK_PORT MTPROTO_BACKEND_HOST MTPROTO_BACKEND_PORT WEB_TLS_HOST WEB_TLS_PORT PUBLIC_HTTPS_PORT
envsubst < "$SD_ROOT/templates/haproxy.cfg.tpl" > "$tmp"
if have haproxy; then haproxy -c -f "$tmp"; else warn "HAProxy binary not found; syntax check skipped"; fi
if [[ "$SD_MODE" == run && "$SD_DRY_RUN" == 0 ]]; then
 if confirm "Save rendered config to $output (not activated)?"; then
  [[ ! -e "$output" ]] || backup_file "$output"
  install -D -m 0600 "$tmp" "$output"
 fi
else
 cat "$tmp"
fi
