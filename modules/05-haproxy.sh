#!/usr/bin/env bash
set -Eeuo pipefail
source "$SD_ROOT/lib/common.sh"
source "$SD_ROOT/lib/config.sh"
load_config
source "$SD_ROOT/lib/port-discovery.sh"
require_root
require_domains

config="${HAPROXY_CONFIG:?HAPROXY_CONFIG is not set}"
binary="${HAPROXY_BIN:-haproxy}"
service="${HAPROXY_SERVICE:?HAPROXY_SERVICE is not set}"
settings="${MTPROXYL_SETTINGS:-$MTProxyL_DIR/settings.conf}"

# This stage intentionally patches the active MTProxyL custom config.
# It never renders or replaces the complete HAProxy configuration.
if [[ ! -f "$config" || -L "$config" || ! -s "$config" || ! -x "$binary" || ! -f "$settings" ]]; then
 if [[ "$SD_MODE" == check || "$SD_DRY_RUN" == 1 ]]; then
  warn "MTProxyL active HAProxy config, binary or settings not found; integration check skipped."
  exit 0
 fi
 die "Required MTProxyL config, HAProxy binary or settings file is missing."
fi

grep -Eq "^[[:space:]]*FRONT_SERVER=['\"]haproxy['\"]" "$settings" ||
 die "MTProxyL FRONT_SERVER is not set to haproxy."
grep -Eq "^[[:space:]]*NGINX_CUSTOM_ENABLED=['\"]true['\"]" "$settings" ||
 die "MTProxyL custom config mode is not enabled; refusing to modify a non-active config."

unit_definition="$(systemctl cat "$service" 2>/dev/null)" || die "Cannot read systemd unit $service."
grep -Fq -- "$config" <<< "$unit_definition" ||
 die "Systemd unit $service does not reference $config; refusing to reload a different config."
grep -Fq -- "$binary" <<< "$unit_definition" ||
 die "Systemd unit $service does not use $binary; configure HAPROXY_BIN to match the active service."
systemctl is-active --quiet "$service" ||
 { [[ "$SD_MODE" == check || "$SD_DRY_RUN" == 1 ]] && warn "$service is not active; a reload will require an active service." || die "$service is not active."; }

have python3 || die "python3 is required for safe HAProxy config editing."
have ss || die "ss (iproute2) is required for listener discovery."

declare -A DISCOVERED=()
while IFS='=' read -r key value; do
 case "$key" in
  PUBLIC_HTTP_PORT|PUBLIC_HTTPS_PORT|XRAY_LOOPBACK_HOST|XRAY_LOOPBACK_PORT|MTPROTO_BACKEND_HOST|MTPROTO_BACKEND_PORT|WEB_TLS_HOST|WEB_TLS_PORT|WEB_HTTP_HOST|WEB_HTTP_PORT|SELFSTEAL_BACKEND_HOST|SELFSTEAL_BACKEND_PORT|STATIC_BACKEND_HOST|STATIC_BACKEND_PORT|SELFSTEAL_PORT)
   DISCOVERED["$key"]="$value"
   ;;
  *) die "Unexpected value returned by HAProxy discovery: $key";;
 esac
done < <(discover_haproxy_ports "$config")

for key in PUBLIC_HTTP_PORT PUBLIC_HTTPS_PORT XRAY_LOOPBACK_HOST XRAY_LOOPBACK_PORT MTPROTO_BACKEND_HOST MTPROTO_BACKEND_PORT WEB_TLS_HOST WEB_TLS_PORT WEB_HTTP_HOST WEB_HTTP_PORT SELFSTEAL_BACKEND_HOST SELFSTEAL_BACKEND_PORT STATIC_BACKEND_HOST STATIC_BACKEND_PORT SELFSTEAL_PORT; do
 [[ -n "${DISCOVERED[$key]:-}" ]] || die "Discovery did not return $key."
done

if [[ "$SD_MODE" == check || "$SD_DRY_RUN" == 1 ]]; then
 info "Discovered HAProxy port layout:"
 for key in PUBLIC_HTTP_PORT PUBLIC_HTTPS_PORT XRAY_LOOPBACK_PORT MTPROTO_BACKEND_PORT WEB_TLS_PORT WEB_HTTP_PORT SELFSTEAL_BACKEND_PORT STATIC_BACKEND_PORT SELFSTEAL_PORT; do
  info "  $key=${DISCOVERED[$key]}"
 done
 info "Check-only mode: no port plan or active config was changed."
 exit 0
fi

[[ -r /dev/tty && -w /dev/tty ]] || die "Interactive HAProxy setup requires a terminal (/dev/tty). Run this stage from an interactive shell."
prompt_value() {
 local name="$1" current="$2" answer
 read -r -p "$name [$current]: " answer </dev/tty
 printf '%s' "${answer:-$current}"
}
prompt_menu() {
 local answer
 {
  printf '\nHAProxy port setup\n'
  printf '  1 - Use the recommended layout discovered from the active MTProxyL config\n'
  printf '  2 - Enter ports manually (unready services will be saved as a pending plan)\n'
  printf '  0 - Exit without changes\n'
 } >/dev/tty
 read -r -p "Select [1/2/0]: " answer </dev/tty
 printf '%s' "$answer"
}
confirm_tty() {
 local answer
 [[ "$SD_MODE" == run && "$SD_DRY_RUN" == 0 ]] || return 1
 [[ "${SD_ASSUME_YES:-0}" == 1 ]] && return 0
 read -r -p "$1 [y/N] " answer </dev/tty
 [[ "$answer" =~ ^[Yy]$ ]]
}
haproxy_bind_ready() {
 local port="$1"
 ss -H -lntp "( sport = :$port )" 2>/dev/null | grep -Eq 'users:\(\("haproxy",'
}

# A pending plan is loaded only as the starting point for manual editing.
HAS_PENDING=0
if [[ -f "$SD_PORT_PLAN_FILE" && ! -L "$SD_PORT_PLAN_FILE" ]]; then
 load_port_plan
 HAS_PENDING=1
 info "A pending port plan exists; its values will be offered as manual-mode defaults."
fi

choice="$(prompt_menu)"
case "$choice" in
 0) info "HAProxy setup cancelled; no changes made."; exit 0;;
 1)
  for key in "${!DISCOVERED[@]}"; do printf -v "$key" '%s' "${DISCOVERED[$key]}"; done
  info "Using the layout discovered in the active HAProxy config."
  ;;
  2)
  # If a pending plan exists, it supplies defaults; otherwise use discovery.
  if (( HAS_PENDING == 0 )); then
   for key in "${!DISCOVERED[@]}"; do printf -v "$key" '%s' "${DISCOVERED[$key]}"; done
  fi
  # Public binds stay as discovered: changing them may break ACME and external routing.
  XRAY_LOOPBACK_PORT="$(prompt_value XRAY_LOOPBACK_PORT "$XRAY_LOOPBACK_PORT")"
  MTPROTO_BACKEND_PORT="$(prompt_value MTPROTO_BACKEND_PORT "$MTPROTO_BACKEND_PORT")"
  WEB_TLS_PORT="$(prompt_value WEB_TLS_PORT "$WEB_TLS_PORT")"
  WEB_HTTP_PORT="$(prompt_value WEB_HTTP_PORT "$WEB_HTTP_PORT")"
  SELFSTEAL_BACKEND_PORT="$(prompt_value SELFSTEAL_BACKEND_PORT "$SELFSTEAL_BACKEND_PORT")"
  STATIC_BACKEND_PORT="$(prompt_value STATIC_BACKEND_PORT "$STATIC_BACKEND_PORT")"
  SELFSTEAL_PORT="$(prompt_value SELFSTEAL_PORT "$SELFSTEAL_PORT")"
  ;;
 *)
  die "Invalid selection. Choose 1, 2 or 0."
  ;;
esac

# Keep public entry points tied to the active configuration; manual mode only
# changes internal service ports and HAProxy's local loopback binds.
PUBLIC_HTTP_PORT="${DISCOVERED[PUBLIC_HTTP_PORT]}"
PUBLIC_HTTPS_PORT="${DISCOVERED[PUBLIC_HTTPS_PORT]}"

for key in PUBLIC_HTTP_PORT PUBLIC_HTTPS_PORT XRAY_LOOPBACK_PORT MTPROTO_BACKEND_PORT WEB_TLS_PORT WEB_HTTP_PORT SELFSTEAL_BACKEND_PORT STATIC_BACKEND_PORT SELFSTEAL_PORT; do
 validate_tcp_port "$key" "${!key}"
done
[[ "$PUBLIC_HTTP_PORT" != "$PUBLIC_HTTPS_PORT" ]] || die "Public HTTP and HTTPS ports must be different."
[[ "$WEB_TLS_PORT" != "$SELFSTEAL_PORT" ]] || die "WEB TLS and Selfmask local bind ports must be different."
for internal_port in "$WEB_TLS_PORT" "$SELFSTEAL_PORT"; do
 [[ "$internal_port" != "$PUBLIC_HTTP_PORT" && "$internal_port" != "$PUBLIC_HTTPS_PORT" ]] ||
  die "An internal HAProxy bind cannot reuse a public entry port ($internal_port)."
done

declare -A backend_endpoint_owner=()
register_backend_endpoint() {
 local label="$1" host="$2" port="$3" endpoint previous
 endpoint="${host}|${port}"
 previous="${backend_endpoint_owner[$endpoint]:-}"
 if [[ -n "$previous" ]]; then
  if [[ "$label" == "Static backend" && "$previous" == "Selfmask backend" ]] ||
     [[ "$label" == "Selfmask backend" && "$previous" == "Static backend" ]]; then
   return 0
  fi
  die "$label and $previous use the same backend endpoint $host:$port."
 fi
 backend_endpoint_owner["$endpoint"]="$label"
}
register_backend_endpoint "Xray" "$XRAY_LOOPBACK_HOST" "$XRAY_LOOPBACK_PORT"
register_backend_endpoint "MTProto" "$MTPROTO_BACKEND_HOST" "$MTPROTO_BACKEND_PORT"
register_backend_endpoint "WEB HTTP" "$WEB_HTTP_HOST" "$WEB_HTTP_PORT"
register_backend_endpoint "WEB TLS" "$WEB_TLS_HOST" "$WEB_TLS_PORT"
register_backend_endpoint "Selfmask backend" "$SELFSTEAL_BACKEND_HOST" "$SELFSTEAL_BACKEND_PORT"
register_backend_endpoint "Static backend" "$STATIC_BACKEND_HOST" "$STATIC_BACKEND_PORT"

info "Selected target port layout:"
for key in PUBLIC_HTTP_PORT PUBLIC_HTTPS_PORT XRAY_LOOPBACK_PORT MTPROTO_BACKEND_PORT WEB_TLS_PORT WEB_HTTP_PORT SELFSTEAL_BACKEND_PORT STATIC_BACKEND_PORT SELFSTEAL_PORT; do
 info "  $key=${!key}"
done

# Public HTTP/HTTPS binds are intentionally retained from discovery. For
# internal HAProxy-owned binds, a changed target must be free before reload.
READY=1
for key in WEB_TLS_PORT SELFSTEAL_PORT; do
 current="${DISCOVERED[$key]}"
 target="${!key}"
 if [[ "$target" != "$current" ]] && ss -H -lnt "( sport = :$target )" 2>/dev/null | grep -q .; then
  warn "$key target port $target is occupied; the plan will remain pending."
  READY=0
 fi
done

check_backend_listener "Xray" "$XRAY_LOOPBACK_HOST" "$XRAY_LOOPBACK_PORT" "${XRAY_LISTENER_PROCESS_HINT:-rw-core}" || READY=0
check_backend_listener "MTProto" "$MTPROTO_BACKEND_HOST" "$MTPROTO_BACKEND_PORT" "${MTPROTO_LISTENER_PROCESS_HINT:-edgeguardd}" || READY=0
check_backend_listener "WEB HTTP" "$WEB_HTTP_HOST" "$WEB_HTTP_PORT" "${WEB_HTTP_LISTENER_PROCESS_HINT:-edgeguardd}" || READY=0
check_backend_listener "MTProxyL Selfmask backend" "$SELFSTEAL_BACKEND_HOST" "$SELFSTEAL_BACKEND_PORT" "${SELFSTEAL_BACKEND_PROCESS_HINT:-${STATIC_LISTENER_PROCESS_HINT:-}}" || READY=0
check_backend_listener "MTProxyL static backend" "$STATIC_BACKEND_HOST" "$STATIC_BACKEND_PORT" "${STATIC_LISTENER_PROCESS_HINT:-}" || READY=0

if (( READY == 0 )); then
 save_port_plan
 warn "Services are not ready for the selected ports. The active HAProxy config was NOT changed and was NOT reloaded."
 warn "Configure the backend services, then rerun: sudo ./install.sh --run --stage haproxy"
 exit 0
fi

tmp="$(mktemp "${config}.server-deployment.XXXXXX")"
cleanup(){ rm -f -- "$tmp" "${new_file:-}" "${restore_file:-}"; }
trap cleanup EXIT

python3 "$SD_ROOT/lib/haproxy_config.py" "$config" "$tmp" \
 --domains "$REMNAWAVE_SNI_DOMAINS" --web-domain "$WEB_DOMAIN" \
 --http-port "$PUBLIC_HTTP_PORT" --https-port "$PUBLIC_HTTPS_PORT" \
 --xray-host "$XRAY_LOOPBACK_HOST" --xray-port "$XRAY_LOOPBACK_PORT" \
 --mtproto-host "$MTPROTO_BACKEND_HOST" --mtproto-port "$MTPROTO_BACKEND_PORT" \
 --web-tls-host "$WEB_TLS_HOST" --web-tls-port "$WEB_TLS_PORT" \
 --web-http-host "$WEB_HTTP_HOST" --web-http-port "$WEB_HTTP_PORT" \
 --static-host "$STATIC_BACKEND_HOST" --static-port "$STATIC_BACKEND_PORT" \
 --selfsteal-backend-host "$SELFSTEAL_BACKEND_HOST" --selfsteal-backend-port "$SELFSTEAL_BACKEND_PORT" \
 --selfsteal-port "$SELFSTEAL_PORT" || die "Could not prepare HAProxy config candidate."

"$binary" -c -q -f "$tmp" || die "HAProxy rejected the proposed config; active config was not changed."
info "HAProxy candidate passed syntax validation."

if cmp -s "$tmp" "$config"; then
 rm -f -- "$SD_PORT_PLAN_FILE"
 info "HAProxy config is already synchronized; no change or reload needed."
 exit 0
fi

confirm_tty "Apply the selected port layout and Remnawave SNI routing to $config, then reload $service?" || {
 info "HAProxy integration cancelled; active config was not changed."
 exit 0
}

backup="${config}.before-server-deployment.$(date -u +%Y%m%dT%H%M%SZ)"
cp -a -- "$config" "$backup"
chmod go-rwx "$backup" 2>/dev/null || true
new_file="${config}.server-deployment-new.$$"
restore_file="${config}.server-deployment-restore.$$"
install -m "$(stat -c '%a' "$config")" "$tmp" "$new_file"
chown --reference="$config" "$new_file"
mv -f -- "$new_file" "$config"

if systemctl reload "$service" && systemctl is-active --quiet "$service" &&
   haproxy_bind_ready "$WEB_TLS_PORT" && haproxy_bind_ready "$SELFSTEAL_PORT"; then
 rm -f -- "$SD_PORT_PLAN_FILE"
 info "HAProxy config updated and $service reloaded successfully."
 info "Backup: $backup"
 exit 0
fi

err "HAProxy reload failed; restoring the previous config."
cp -a -- "$backup" "$restore_file"
mv -f -- "$restore_file" "$config"
if systemctl reload "$service"; then
 err "Previous config restored and reloaded. The deployment change was rolled back."
else
 err "Previous config restored on disk, but reload also failed. Inspect $service immediately."
fi
exit 1
