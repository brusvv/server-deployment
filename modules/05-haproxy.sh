#!/usr/bin/env bash
set -Eeuo pipefail
source "$SD_ROOT/lib/common.sh"
source "$SD_ROOT/lib/config.sh"
require_root
require_domains

config="${HAPROXY_CONFIG:?HAPROXY_CONFIG is not set}"
binary="${HAPROXY_BIN:-haproxy}"
service="${HAPROXY_SERVICE:?HAPROXY_SERVICE is not set}"
settings="${MTPROXYL_SETTINGS:-$MTProxyL_DIR/settings.conf}"
domains="$REMNAWAVE_SNI_DOMAINS"

# This stage intentionally patches the active MTProxyL custom config.
# It never renders or replaces the complete HAProxy configuration.
if [[ ! -s "$config" || ! -x "$binary" || ! -f "$settings" ]]; then
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

systemctl cat "$service" 2>/dev/null | grep -Fq -- "$config" ||
 die "Systemd unit $service does not reference $config; refusing to reload a different config."
systemctl is-active --quiet "$service" ||
 { [[ "$SD_MODE" == check || "$SD_DRY_RUN" == 1 ]] && warn "$service is not active; reload will require an active service." || die "$service is not active."; }

have python3 || die "python3 is required for safe HAProxy config editing."
tmp="$(mktemp "${config}.server-deployment.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

python3 - "$config" "$tmp" "$domains" "$WEB_DOMAIN" "$XRAY_LOOPBACK_HOST" "$XRAY_LOOPBACK_PORT" <<'PY'
import re
import sys
from pathlib import Path

source, target, raw_domains, web_domain, xray_host, xray_port = sys.argv[1:]
domains = [item for item in re.split(r"[\s,]+", raw_domains.strip()) if item]
if not domains:
    raise SystemExit("ERROR: REMNAWAVE_SNI_DOMAINS is empty")
domain_re = re.compile(r"^(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$")
seen = set()
for domain in domains:
    if not domain_re.fullmatch(domain):
        raise SystemExit(f"ERROR: invalid Remnawave SNI domain: {domain}")
    key = domain.lower()
    if key in seen:
        raise SystemExit(f"ERROR: duplicate Remnawave SNI domain: {domain}")
    seen.add(key)
if web_domain.lower() in seen:
    raise SystemExit("ERROR: WEB_DOMAIN must not also appear in REMNAWAVE_SNI_DOMAINS")
if not re.fullmatch(r"[A-Za-z0-9_.:-]+", xray_host) or any(c.isspace() for c in xray_host):
    raise SystemExit("ERROR: invalid XRAY_LOOPBACK_HOST")
if not xray_port.isdigit() or not (1 <= int(xray_port) <= 65535):
    raise SystemExit("ERROR: invalid XRAY_LOOPBACK_PORT")

path = Path(source)
text = path.read_text()
lines = text.splitlines(keepends=True)
header_re = re.compile(r"^(?:global|defaults|frontend\s+\S+|backend\s+\S+|listen\s+\S+)\s*(?:#.*)?$")
headers = [i for i, line in enumerate(lines) if header_re.match(line.rstrip("\r\n"))]

def section(name, kind):
    matches = [i for i in headers if lines[i].strip() == f"{kind} {name}"]
    if len(matches) != 1:
        raise SystemExit(f"ERROR: expected exactly one {kind} {name}, found {len(matches)}")
    start = matches[0]
    end = next((i for i in headers if i > start), len(lines))
    return start, end

start, end = section("mtproxyl_public", "frontend")
block = lines[start:end]
acl_matches = [i for i, line in enumerate(block) if re.match(r"^\s*acl\s+remnawave_sni\b", line)]
route_matches = [i for i, line in enumerate(block) if re.match(r"^\s*use_backend\s+remnawave_xray\s+if\s+remnawave_sni\b", line)]
web_matches = [i for i, line in enumerate(block) if "use_backend mtproxyl_web_tls" in line and "req.ssl_sni" in line and web_domain.lower() in line.lower()]
default_matches = [i for i, line in enumerate(block) if re.match(r"^\s*default_backend\s+mtproxyl_mtproto\b", line)]
if len(acl_matches) > 1 or len(route_matches) > 1:
    raise SystemExit("ERROR: duplicate Remnawave ACL or route in frontend mtproxyl_public")
if len(web_matches) != 1:
    raise SystemExit("ERROR: expected exactly one WEB SNI route matching WEB_DOMAIN in frontend mtproxyl_public")
if len(default_matches) != 1:
    raise SystemExit("ERROR: expected exactly one MTProto default_backend in frontend mtproxyl_public")

indent = "    "
if acl_matches:
    idx = acl_matches[0]
    indent = re.match(r"^\s*", block[idx]).group(0)
    block[idx] = f"{indent}acl remnawave_sni req.ssl_sni -i {' '.join(domains)}\n"
else:
    insert_at = route_matches[0] if route_matches else default_matches[0]
    block.insert(insert_at, f"{indent}acl remnawave_sni req.ssl_sni -i {' '.join(domains)}\n")
    # The insertion shifts the route/default positions; locate again.
    route_matches = [i for i, line in enumerate(block) if re.match(r"^\s*use_backend\s+remnawave_xray\s+if\s+remnawave_sni\b", line)]
if not route_matches:
    acl_idx = next(i for i, line in enumerate(block) if re.match(r"^\s*acl\s+remnawave_sni\b", line))
    block.insert(acl_idx + 1, f"{indent}use_backend remnawave_xray if remnawave_sni\n")

lines[start:end] = block
# Recompute section positions after the frontend edit.
headers = [i for i, line in enumerate(lines) if header_re.match(line.rstrip("\r\n"))]
bstart, bend = section("remnawave_xray", "backend")
server_matches = []
for i in range(bstart + 1, bend):
    match = re.match(r"^(\s*server\s+remnawave\s+)(\S+)(.*)$", lines[i].rstrip("\r\n"))
    if match:
        server_matches.append((i, match))
if len(server_matches) != 1:
    raise SystemExit(f"ERROR: expected exactly one 'server remnawave' in backend remnawave_xray, found {len(server_matches)}")
i, match = server_matches[0]
newline = "\r\n" if lines[i].endswith("\r\n") else "\n"
lines[i] = f"{match.group(1)}{xray_host}:{xray_port}{match.group(3)}{newline}"

Path(target).write_text("".join(lines))
PY

"$binary" -c -q -f "$tmp" || die "HAProxy rejected the proposed config; active config was not changed."
info "HAProxy candidate passed syntax validation."
info "Remnawave SNI domains: $domains"
info "Xray backend: $XRAY_LOOPBACK_HOST:$XRAY_LOOPBACK_PORT"

if cmp -s "$tmp" "$config"; then
 info "HAProxy config is already synchronized; no change or reload needed."
 exit 0
fi

if [[ "$SD_MODE" != run || "$SD_DRY_RUN" == 1 ]]; then
 info "Check-only: proposed MTProxyL config changes validated; active file was not changed."
 exit 0
fi

confirm "Update only the Remnawave ACL/backend in $config and reload $service?" || {
 info "HAProxy integration cancelled; active config was not changed."
 exit 0
}

backup="${config}.before-server-deployment.$(date -u +%Y%m%dT%H%M%SZ)"
cp -a -- "$config" "$backup"
chmod go-rwx "$backup" 2>/dev/null || true
new_file="${config}.server-deployment-new.$$"
restore_file="${config}.server-deployment-restore.$$"
cleanup(){ rm -f -- "$new_file" "$restore_file"; }
trap cleanup EXIT
install -m "$(stat -c '%a' "$config")" "$tmp" "$new_file"
chown --reference="$config" "$new_file"
mv -f -- "$new_file" "$config"

if systemctl reload "$service" && systemctl is-active --quiet "$service"; then
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
