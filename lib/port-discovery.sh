#!/usr/bin/env bash
# HAProxy port discovery and pending-plan helpers.
set -Eeuo pipefail

SD_PORT_PLAN_FILE="${SD_PORT_PLAN_FILE:-${STATE_DIR:-/var/lib/server-deployment}/haproxy-ports.pending}"

discover_haproxy_ports() {
  local config="$1"
  [[ -r "$config" ]] || die "Cannot read HAProxy config for discovery: $config"
  python3 - "$config" "${XRAY_LOOPBACK_HOST:-127.0.0.1}" "${XRAY_LOOPBACK_PORT:-1443}" "${ACME_WEBROOT_HOST:-127.0.0.1}" "${ACME_WEBROOT_PORT:-18080}" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
default_xray_host, default_xray_port = sys.argv[2], int(sys.argv[3])
default_acme_host, default_acme_port = sys.argv[4], int(sys.argv[5])
lines = text.splitlines()
sections = {}
current = None
for number, raw in enumerate(lines, 1):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    match = re.match(r"^(global|defaults|frontend|backend|listen)(?:\s+(\S+))?\s*$", line)
    if match:
        kind, name = match.groups()
        current = (kind, name)
        sections.setdefault(current, []).append((number, raw))
    elif current:
        sections[current].append((number, raw))

def one_section(kind, name):
    matches = [v for (k, n), v in sections.items() if k == kind and n == name]
    if len(matches) != 1:
        raise SystemExit(f"discovery error: expected one {kind} {name}, found {len(matches)}")
    return matches[0]

def endpoint(raw, context):
    # HAProxy server endpoint supports host:port and [IPv6]:port.
    m = re.search(r"\bserver\s+\S+\s+(\[[^]]+\]|[^\s:]+):(\d+)\b", raw)
    if not m:
        raise SystemExit(f"discovery error: cannot parse server endpoint in {context}: {raw.strip()}")
    return m.group(1).strip("[]"), int(m.group(2))

def server(kind, section, server_name):
    rows = one_section(kind, section)
    found = [raw for _, raw in rows if re.match(rf"^\\s*server\\s+{re.escape(server_name)}\\s+", raw)]
    if len(found) != 1:
        raise SystemExit(f"discovery error: expected one server {server_name} in {kind} {section}, found {len(found)}")
    return endpoint(found[0], f"{kind} {section}/{server_name}")


def server_any(kind, names, server_name):
    matches = [rows for (section_kind, section_name), rows in sections.items()
               if section_kind == kind and section_name in names]
    if len(matches) != 1:
        raise SystemExit(
            f"discovery error: expected exactly one of {kind} {', '.join(names)}, found {len(matches)}"
        )
    rows = matches[0]
    found = [raw for _, raw in rows if re.match(rf"^\\s*server\\s+{re.escape(server_name)}\\s+", raw)]
    if len(found) != 1:
        raise SystemExit(f"discovery error: expected one server {server_name} in {kind} WEB backend, found {len(found)}")
    return endpoint(found[0], f"{kind} WEB/{server_name}")

def bind(section):
    rows = one_section("frontend", section)
    found = []
    for _, raw in rows:
        m = re.match(r"^\s*bind\s+(\S+)", raw)
        if m:
            # This orchestrator manages one TCP bind per target frontend.
            token = m.group(1)
            if token.startswith("unix@") or token.startswith("/"):
                continue
            mport = re.search(r":(\d+)$", token)
            if not mport:
                raise SystemExit(f"discovery error: cannot parse bind port in frontend {section}: {token}")
            found.append(int(mport.group(1)))
    if len(found) != 1:
        raise SystemExit(f"discovery error: expected one TCP bind in frontend {section}, found {len(found)}")
    return found[0]

web_tls_endpoint = server("backend", "mtproxyl_web_tls", "web_tls")
web_tls_bind_port = bind("mtproxyl_web")
if web_tls_bind_port != web_tls_endpoint[1]:
    raise SystemExit(
        "discovery error: frontend mtproxyl_web bind port does not match "
        "backend mtproxyl_web_tls server port"
    )
selfsteal_backend_endpoint = server("backend", "mtproxyl_site", "site")
static_backend_endpoint = server("backend", "mtproxyl_static", "static")

acme_sections = [v for (k, n), v in sections.items() if k == "backend" and n == "mtproxyl_acme"]
if len(acme_sections) > 1:
    raise SystemExit("discovery error: expected at most one backend mtproxyl_acme")
if acme_sections:
    acme_endpoint = server("backend", "mtproxyl_acme", "acme")
    acme_backend_present = "true"
else:
    acme_endpoint = (default_acme_host, default_acme_port)
    acme_backend_present = "false"

xray_sections = [v for (k, n), v in sections.items() if k == "backend" and n == "remnawave_xray"]
if len(xray_sections) > 1:
    raise SystemExit("discovery error: expected at most one backend remnawave_xray")
if xray_sections:
    xray_endpoint = server("backend", "remnawave_xray", "remnawave")
    xray_backend_present = "true"
else:
    xray_endpoint = (default_xray_host, default_xray_port)
    xray_backend_present = "false"

values = {
    "PUBLIC_HTTP_PORT": bind("mtproxyl_http"),
    "PUBLIC_HTTPS_PORT": bind("mtproxyl_public"),
    "XRAY_BACKEND_PRESENT": xray_backend_present,
    "XRAY_LOOPBACK": xray_endpoint,
    "MTPROTO_BACKEND": server("backend", "mtproxyl_mtproto", "mtproto"),
    "WEB_TLS": web_tls_endpoint,
    "WEB_HTTP": server_any("backend", ("mtproxyl_web", "mtproxyl_web_backend"), "web"),
    "SELFSTEAL_BACKEND": selfsteal_backend_endpoint,
    "STATIC_BACKEND": static_backend_endpoint,
    "SELFSTEAL_PORT": bind("mtproxyl_selfmask"),
    "ACME_BACKEND_PRESENT": acme_backend_present,
    "ACME_WEBROOT": acme_endpoint,
}
for key, value in values.items():
    if isinstance(value, tuple):
        print(f"{key}_HOST={value[0]}")
        print(f"{key}_PORT={value[1]}")
    else:
        print(f"{key}={value}")
PY
}

validate_tcp_port() {
  local name="$1" value="$2"
  [[ "$value" =~ ^[0-9]{1,5}$ ]] || die "$name must be an integer from 1 to 65535."
  (( value >= 1 && value <= 65535 )) || die "$name is outside the valid TCP port range."
}

save_port_plan() {
  local destination="$SD_PORT_PLAN_FILE" key value
  install -d -m 0700 "$(dirname -- "$destination")"
  local tmp
  tmp="$(mktemp "${destination}.XXXXXX")"
  {
    printf '# Pending HAProxy port plan; generated by server-deployment.\n'
    for key in PUBLIC_HTTP_PORT PUBLIC_HTTPS_PORT XRAY_LOOPBACK_HOST XRAY_LOOPBACK_PORT MTPROTO_BACKEND_HOST MTPROTO_BACKEND_PORT WEB_TLS_HOST WEB_TLS_PORT WEB_HTTP_HOST WEB_HTTP_PORT SELFSTEAL_BACKEND_HOST SELFSTEAL_BACKEND_PORT STATIC_BACKEND_HOST STATIC_BACKEND_PORT SELFSTEAL_PORT; do
      value="${!key}"
      printf '%s=%q\n' "$key" "$value"
    done
  } > "$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$destination"
  info "Pending HAProxy port plan saved to $destination"
}

load_port_plan() {
  [[ -f "$SD_PORT_PLAN_FILE" && ! -L "$SD_PORT_PLAN_FILE" ]] || return 1
  # File is generated locally, root-only, and never sourced from the repository.
  # shellcheck disable=SC1090
  source "$SD_PORT_PLAN_FILE"
  return 0
}

check_backend_listener() {
  local label="$1" host="$2" port="$3"
  validate_tcp_port "$label" "$port"
  local listeners
  local process_hint="${4:-}"
  listeners="$(ss -H -lntp "( sport = :$port )" 2>/dev/null || true)"
  if python3 - "$host" "$port" "$process_hint" "$listeners" <<'PY'
import re
import socket
import sys

requested, port, process_hint, output = sys.argv[1:]
try:
    requested_set = {item[4][0] for item in socket.getaddrinfo(requested, None, type=socket.SOCK_STREAM)}
except socket.gaierror:
    requested_set = {requested}
requested_set.update({requested, requested.strip("[]")})
requested_wildcard = requested in {"*", "0.0.0.0", "::"}
for line in output.splitlines():
    fields = line.split()
    if len(fields) < 4:
        continue
    local = fields[3]
    try:
        local_host, local_port = local.rsplit(":", 1)
    except ValueError:
        continue
    local_host = local_host.strip("[]")
    process = re.search(r'users:\(\("([^"]+)"', line)
    if process_hint and (not process or process_hint not in process.group(1)):
        continue
    host_matches = local_host in requested_set
    if requested_wildcard and local_host in {"*", "0.0.0.0", "::"}:
        host_matches = True
    if local_port == port and host_matches:
        raise SystemExit(0)
raise SystemExit(1)
PY
  then
    info "$label listener detected on $host:$port"
    return 0
  fi
  warn "$label is not listening on the requested endpoint $host:$port yet; plan remains pending."
  return 1
}
