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


def newline_for(lines: list[str]) -> str:
    for line in lines:
        if line.endswith("\r\n"):
            return "\r\n"
        if line.endswith("\n"):
            return "\n"
    return "\n"


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


def parse_domain_list(raw: str, label: str, allow_empty: bool = False) -> list[str]:
    domains = [item for item in re.split(r"[\s,]+", raw.strip()) if item]
    domain_re = re.compile(r"^(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$")
    seen = set()
    for domain in domains:
        if not domain_re.fullmatch(domain):
            raise ValueError(f"invalid {label} domain: {domain}")
        if domain.lower() in seen:
            raise ValueError(f"duplicate {label} domain: {domain}")
        seen.add(domain.lower())
    if not domains and not allow_empty:
        raise ValueError(f"{label} domain list must not be empty")
    return domains


def validate(args):
    ports = [
        args.http_port, args.https_port, args.xray_port, args.mtproto_port,
        args.web_tls_port, args.web_http_port, args.static_port,
        args.selfsteal_backend_port, args.selfsteal_port, args.acme_port,
    ]
    for port in ports:
        if not port.isdigit() or not 1 <= int(port) <= 65535:
            raise ValueError(f"invalid TCP port: {port}")
    for host in [
        args.xray_host, args.mtproto_host, args.web_tls_host, args.web_http_host,
        args.static_host, args.selfsteal_backend_host, args.acme_host,
    ]:
        if not host or any(c.isspace() for c in host) or not re.fullmatch(r"[A-Za-z0-9_.:\[\]-]+", host):
            raise ValueError(f"invalid backend host: {host}")


def rename_web_backend(lines: list[str]) -> str:
    """Avoid a frontend/backend name collision in HAProxy 3.3+."""
    section = parse_sections(lines)
    old_headers = [
        i for i, line in enumerate(lines)
        if line.strip() == "backend mtproxyl_web"
    ]
    new_headers = [
        i for i, line in enumerate(lines)
        if line.strip() == "backend mtproxyl_web_backend"
    ]
    if len(old_headers) > 1 or len(new_headers) > 1 or (old_headers and new_headers):
        raise ValueError("expected one legacy or renamed MTProxyL WEB backend, not both")

    start, end = section("frontend", "mtproxyl_web")
    block = lines[start:end]
    old_refs = [i for i, line in enumerate(block) if re.match(r"^\s*default_backend\s+mtproxyl_web\s*$", line)]
    new_refs = [i for i, line in enumerate(block) if re.match(r"^\s*default_backend\s+mtproxyl_web_backend\s*$", line)]
    if len(old_refs) + len(new_refs) != 1:
        raise ValueError("expected exactly one WEB frontend default_backend reference")

    if old_headers:
        index = old_headers[0]
        newline = "\r\n" if lines[index].endswith("\r\n") else "\n"
        lines[index] = f"backend mtproxyl_web_backend{newline}"
    elif not new_headers:
        raise ValueError("MTProxyL WEB backend was not found")

    if old_refs:
        index = start + old_refs[0]
        newline = "\r\n" if lines[index].endswith("\r\n") else "\n"
        lines[index] = f"    default_backend mtproxyl_web_backend{newline}"
    return "mtproxyl_web_backend"


def patch_http_frontend(lines: list[str], redirect_domains: list[str], acme_host: str, acme_port: str):
    """Opt-in same-host HTTPS redirects while keeping HTTP-01 reachable."""
    if not redirect_domains:
        return

    section = parse_sections(lines)
    start, end = section("frontend", "mtproxyl_http")
    block = lines[start:end]
    defaults = [i for i, line in enumerate(block) if re.match(r"^\s*default_backend\s+\S+", line)]
    if len(defaults) != 1:
        raise ValueError("expected exactly one default_backend in frontend mtproxyl_http")

    kept = []
    for line in block:
        stripped = line.strip()
        if re.match(r"^acl\s+acme\b", stripped):
            continue
        # Remove rules emitted by this patcher and the equivalent known_http_host
        # form that was applied manually during the server-side rollout.
        if re.match(r"^acl\s+(?:sd_http_redirect_hosts|known_http_host)\b", stripped):
            continue
        if re.match(r"^http-request\s+deny\s+deny_status\s+404\s+unless\s+(?:sd_http_redirect_hosts|known_http_host)\b", stripped):
            continue
        if re.match(r"^http-request\s+redirect\s+scheme\s+https\s+code\s+301\s+if\s+(?:sd_http_redirect_hosts|known_http_host)\s+!acme$", stripped):
            continue
        if re.match(r"^use_backend\s+mtproxyl_acme\s+if\s+acme$", stripped):
            continue
        # Replace the legacy single-host redirect and strict non-ACME reject
        # previously used by MTProxyL and the first manual integration.
        if re.match(r"^http-request\s+redirect\b.*\s+if\s+!acme\b", stripped):
            continue
        if re.match(r"^http-request\s+reject\s+if\s+!acme$", stripped):
            continue
        kept.append(line)

    default_index = next(i for i, line in enumerate(kept) if re.match(r"^\s*default_backend\s+\S+", line))
    nl = newline_for(block)
    rules = [
        f"    acl acme path_beg /.well-known/acme-challenge/{nl}",
        f"    acl sd_http_redirect_hosts hdr(host),field(1,:) -i {' '.join(redirect_domains)}{nl}",
        f"    http-request deny deny_status 404 unless sd_http_redirect_hosts{nl}",
        f"    http-request redirect scheme https code 301 if sd_http_redirect_hosts !acme{nl}",
        f"    use_backend mtproxyl_acme if acme{nl}",
    ]
    block = kept[:default_index] + rules + kept[default_index:]
    lines[start:end] = block


def ensure_acme_backend(lines: list[str], host: str, port: str):
    headers = [i for i, line in enumerate(lines) if line.strip() == "backend mtproxyl_acme"]
    if len(headers) > 1:
        raise ValueError("duplicate backend mtproxyl_acme")
    section = parse_sections(lines)
    if headers:
        replace_server(lines, section, "mtproxyl_acme", "acme", host, port)
    else:
        if lines and not lines[-1].endswith(("\n", "\r")):
            lines[-1] += "\n"
        nl = newline_for(lines)
        lines.extend([
            nl,
            f"backend mtproxyl_acme{nl}",
            f"    server acme {host}:{port}{nl}",
        ])


def patch(args):
    validate(args)
    path = Path(args.source)
    with path.open("r", newline="") as handle:
        text = handle.read()
    lines = text.splitlines(keepends=True)

    domains = parse_domain_list(args.domains, "Remnawave SNI")
    redirect_domains = parse_domain_list(args.redirect_domains, "HTTP redirect", allow_empty=True)
    if args.web_domain.lower() in {domain.lower() for domain in domains}:
        raise ValueError("WEB_DOMAIN must not also appear in REMNAWAVE_SNI_DOMAINS")

    section = parse_sections(lines)
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
    if any(line.strip() == "backend remnawave_xray" for line in lines):
        replace_server(lines, section, "remnawave_xray", "remnawave", args.xray_host, args.xray_port)
    else:
        if lines and not lines[-1].endswith("\n"):
            lines[-1] += "\n"
        lines.extend([
            "\n",
            "backend remnawave_xray\n",
            "    mode tcp\n",
            f"    server remnawave {args.xray_host}:{args.xray_port}\n",
        ])
    replace_server(lines, section, "mtproxyl_mtproto", "mtproto", args.mtproto_host, args.mtproto_port)
    replace_server(lines, section, "mtproxyl_web_tls", "web_tls", args.web_tls_host, args.web_tls_port)
    replace_server(lines, section, "mtproxyl_site", "site", args.selfsteal_backend_host, args.selfsteal_backend_port)
    replace_server(lines, section, "mtproxyl_static", "static", args.static_host, args.static_port)

    web_backend_name = rename_web_backend(lines)
    section = parse_sections(lines)
    replace_server(lines, section, web_backend_name, "web", args.web_http_host, args.web_http_port)

    patch_http_frontend(lines, redirect_domains, args.acme_host, args.acme_port)
    if redirect_domains:
        ensure_acme_backend(lines, args.acme_host, args.acme_port)

    Path(args.target).write_text("".join(lines))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source")
    parser.add_argument("target")
    parser.add_argument("--domains", required=True)
    parser.add_argument("--web-domain", required=True)
    parser.add_argument("--redirect-domains", default="")
    parser.add_argument("--acme-host", default="127.0.0.1")
    parser.add_argument("--acme-port", default="18080")
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
