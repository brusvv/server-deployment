#!/usr/bin/env python3
"""Conservative editor for the MTProxyL-managed HAProxy config."""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


HEADER = re.compile(r"^(?:global|defaults|frontend\s+\S+|backend\s+\S+|listen\s+\S+)\s*(?:#.*)?$")


def parse_sections(lines: list[str]):
    headers = [i for i, line in enumerate(lines) if HEADER.match(line.rstrip("\r\n"))]

    def section(kind: str, name: str):
        matches = [i for i in headers if lines[i].strip() == f"{kind} {name}"]
        if len(matches) != 1:
            raise ValueError(f"expected exactly one {kind} {name}, found {len(matches)}")
        start = matches[0]
        end = next((i for i in headers if i > start), len(lines))
        return start, end

    return section


def replace_bind(lines: list[str], section, name: str, port: str):
    start, end = section("frontend", name)
    found = []
    for i in range(start + 1, end):
        match = re.match(r"^(\s*bind\s+)(\S+)(.*)$", lines[i].rstrip("\r\n"))
        if match:
            token = match.group(2)
            if token.startswith("unix@") or token.startswith("/"):
                continue
            if not re.search(r":\d+$", token):
                raise ValueError(f"cannot parse bind endpoint in frontend {name}: {token}")
            found.append((i, match))
    if len(found) != 1:
        raise ValueError(f"expected exactly one TCP bind in frontend {name}, found {len(found)}")
    i, match = found[0]
    newline = "\r\n" if lines[i].endswith("\r\n") else ("\n" if lines[i].endswith("\n") else "")
    token = re.sub(r":\d+$", f":{port}", match.group(2))
    lines[i] = f"{match.group(1)}{token}{match.group(3)}{newline}"


def replace_server(lines: list[str], section, name: str, server_name: str, host: str, port: str):
    start, end = section("backend", name)
    found = []
    for i in range(start + 1, end):
        raw = lines[i].rstrip("\r\n")
        match = re.match(rf"^(\s*server\s+{re.escape(server_name)}\s+)(\[[^]]+\]|[^\s:]+):(\d+)(.*)$", raw)
        if match:
            found.append((i, match))
    if len(found) != 1:
        raise ValueError(f"expected exactly one server {server_name} in backend {name}, found {len(found)}")
    i, match = found[0]
    newline = "\r\n" if lines[i].endswith("\r\n") else ("\n" if lines[i].endswith("\n") else "")
    formatted_host = f"[{host}]" if ":" in host and not host.startswith("[") else host
    lines[i] = f"{match.group(1)}{formatted_host}:{port}{match.group(4)}{newline}"


def validate(args):
    ports = [args.http_port, args.https_port, args.xray_port, args.mtproto_port,
             args.web_tls_port, args.web_http_port, args.static_port, args.selfsteal_backend_port, args.selfsteal_port]
    for port in ports:
        if not port.isdigit() or not 1 <= int(port) <= 65535:
            raise ValueError(f"invalid TCP port: {port}")
    for host in [args.xray_host, args.mtproto_host, args.web_tls_host, args.web_http_host, args.static_host, args.selfsteal_backend_host]:
        if not host or any(c.isspace() for c in host) or not re.fullmatch(r"[A-Za-z0-9_.:\[\]-]+", host):
            raise ValueError(f"invalid backend host: {host}")


def patch(args):
    validate(args)
    path = Path(args.source)
    with path.open("r", newline="") as handle:
        text = handle.read()
    lines = text.splitlines(keepends=True)
    section = parse_sections(lines)

    domains = [item for item in re.split(r"[\s,]+", args.domains.strip()) if item]
    domain_re = re.compile(r"^(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$")
    seen = set()
    for domain in domains:
        if not domain_re.fullmatch(domain):
            raise ValueError(f"invalid Remnawave SNI domain: {domain}")
        if domain.lower() in seen:
            raise ValueError(f"duplicate Remnawave SNI domain: {domain}")
        seen.add(domain.lower())
    if args.web_domain.lower() in seen:
        raise ValueError("WEB_DOMAIN must not also appear in REMNAWAVE_SNI_DOMAINS")

    start, end = section("frontend", "mtproxyl_public")
    block = lines[start:end]
    acl = [i for i, line in enumerate(block) if re.match(r"^\s*acl\s+remnawave_sni\b", line)]
    route = [i for i, line in enumerate(block) if re.match(r"^\s*use_backend\s+remnawave_xray\s+if\s+remnawave_sni\b", line)]
    web_route = [i for i, line in enumerate(block) if "use_backend mtproxyl_web_tls" in line and "req.ssl_sni" in line and args.web_domain.lower() in line.lower()]
    default = [i for i, line in enumerate(block) if re.match(r"^\s*default_backend\s+mtproxyl_mtproto\b", line)]
    if len(acl) > 1 or len(route) > 1:
        raise ValueError("duplicate Remnawave ACL or route in frontend mtproxyl_public")
    if len(web_route) != 1 or len(default) != 1:
        raise ValueError("expected exactly one WEB SNI route and MTProto default backend")
    if acl:
        i = acl[0]
        indent = re.match(r"^\s*", block[i]).group(0)
        nl = "\r\n" if block[i].endswith("\r\n") else "\n"
        block[i] = f"{indent}acl remnawave_sni req.ssl_sni -i {' '.join(domains)}{nl}"
    else:
        insert_at = route[0] if route else default[0]
        block.insert(insert_at, f"    acl remnawave_sni req.ssl_sni -i {' '.join(domains)}\n")
    if not route:
        acl_i = next(i for i, line in enumerate(block) if re.match(r"^\s*acl\s+remnawave_sni\b", line))
        block.insert(acl_i + 1, "    use_backend remnawave_xray if remnawave_sni\n")
    lines[start:end] = block

    section = parse_sections(lines)
    replace_bind(lines, section, "mtproxyl_http", args.http_port)
    replace_bind(lines, section, "mtproxyl_public", args.https_port)
    replace_bind(lines, section, "mtproxyl_selfmask", args.selfsteal_port)
    replace_bind(lines, section, "mtproxyl_web", args.web_tls_port)
    replace_server(lines, section, "remnawave_xray", "remnawave", args.xray_host, args.xray_port)
    replace_server(lines, section, "mtproxyl_mtproto", "mtproto", args.mtproto_host, args.mtproto_port)
    replace_server(lines, section, "mtproxyl_web_tls", "web_tls", args.web_tls_host, args.web_tls_port)
    replace_server(lines, section, "mtproxyl_web", "web", args.web_http_host, args.web_http_port)
    replace_server(lines, section, "mtproxyl_site", "site", args.selfsteal_backend_host, args.selfsteal_backend_port)
    replace_server(lines, section, "mtproxyl_static", "static", args.static_host, args.static_port)

    Path(args.target).write_text("".join(lines))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source")
    parser.add_argument("target")
    parser.add_argument("--domains", required=True)
    parser.add_argument("--web-domain", required=True)
    for key in ("http-port", "https-port", "xray-port", "mtproto-port", "web-tls-port", "web-http-port", "static-port", "selfsteal-backend-port", "selfsteal-port"):
        parser.add_argument(f"--{key}", required=True)
    for key in ("xray-host", "mtproto-host", "web-tls-host", "web-http-host", "static-host", "selfsteal-backend-host"):
        parser.add_argument(f"--{key}", required=True)
    args = parser.parse_args()
    try:
        patch(args)
    except (OSError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
