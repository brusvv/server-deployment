# Validated server baseline — 2026-11-18

This note records the behavior verified on one reference server while integrating MTProxyL, Docker, HAProxy, ACME HTTP-01 and the not-yet-installed Remnawave stack. It intentionally contains no real domains, public IP addresses, credentials or certificate material.

## Confirmed software and services

| Component | Verified state |
|---|---|
| OS | Ubuntu 24.04 |
| MTProxyL Telemt | 3.5.17; service active |
| MTProxyL HAProxy | 3.2.25; service active |
| Docker Engine | 29.10.0; service active |
| Docker Compose | v5.8.0 |
| Certbot | 2.9.0 |
| ACME webroot | Nginx container, loopback-only |
| Remnawave Panel / Node | Not installed at the time of validation |

Docker was verified by successfully running the `hello-world` container.

## Validated listener layout

| Bind | Purpose |
|---|---|
| `0.0.0.0:80` | HAProxy HTTP frontend |
| `0.0.0.0:443` | HAProxy TCP/SNI frontend |
| `127.0.0.1:8444` | MTProxyL Selfmask frontend |
| `127.0.0.1:15443` | Telemt MTProto backend |
| `127.0.0.1:15444` | MTProxyL WEB TLS frontend |
| `127.0.0.1:15080` | MTProxyL WEB HTTP backend |
| `127.0.0.1:15481` | MTProxyL static/Selfmask backend |
| `127.0.0.1:18080` | ACME HTTP-01 webroot container |
| `127.0.0.1:1443` | Reserved HAProxy Xray target; no listener yet |

The ACME container maps `127.0.0.1:18080:80` and mounts `/var/www/acme` read-only at `/usr/share/nginx/html`. It is not exposed directly to the Internet.

## HAProxy behavior verified

- HTTP requests for the five explicitly configured hostnames return `301` redirects to the same hostname over HTTPS.
- Unknown HTTP Host values are rejected with `404`.
- Requests under `/.well-known/acme-challenge/` bypass the redirect and are routed to the ACME webroot backend.
- A test challenge file was successfully fetched through the public HAProxy HTTP frontend.
- The public HTTPS frontend remains TCP/SNI passthrough: WEB SNI goes to MTProxyL WEB TLS; the configured Remnawave SNI names go to `127.0.0.1:1443`; other SNI traffic uses the MTProto default backend.
- The WEB backend was renamed from `mtproxyl_web` to `mtproxyl_web_backend` to avoid the frontend/backend name collision warning emitted by HAProxy 3.2.25.
- MTProxyL unknown-SNI policy is set to `mask`, with masking target `127.0.0.1:8444`.

The HTTP check returned `301` for all five configured hostnames. ACME was separately verified by fetching a temporary probe file through HAProxy.

## Certificates and renewal

- Existing MTProxyL certificates for its own hostnames were left unchanged.
- One ECDSA SAN certificate was issued for the three Remnawave-related hostnames using Certbot `webroot` and HTTP-01.
- The HTTP-01 dry run succeeded before the production certificate request.
- Certbot's systemd timer was active during validation.
- No deploy-hook was configured at that time. The new certificate was not yet attached to a Panel reverse proxy or Xray listener.

FreeDNS public subdomains were used for DNS. The DNS-01 plugin for FreeDNS public subdomains is not the selected automation path; HTTP-01 was verified instead.

## Explicitly not completed

- Remnawave Panel, PostgreSQL, Redis/Valkey, Subscription Page and Remnawave Node/Xray were not installed.
- The reserved Xray listener on `127.0.0.1:1443` was not active.
- All three Remnawave SNI hostnames still route to the Xray backend. This baseline does **not** implement separate HTTPS routing for a Panel hostname or Subscription Page hostname.
- The new SAN certificate was issued but not wired into a reverse proxy, Node or deploy-hook.
- The external scanner's report about an eGames SelfSteal website fingerprint was not conclusively verified. The inspected home pages did not show the specific title/asset markers that were searched for, but that limited check is not proof that every path or hostname is free of the fingerprint.
- UFW was inactive and SSH was listening on TCP/22 on IPv4 and IPv6. No firewall policy was changed.

## Resource constraints observed

At the time of the resource check:

- 1 vCPU
- approximately 1.9 GiB RAM
- 512 MiB swap
- 25 GB root filesystem, approximately 19 GB free

The operator cannot resize this VPS and elected to attempt a staged Remnawave installation anyway. Resource monitoring and conservative component-by-component installation are therefore required. These values are a snapshot, not a sizing recommendation.

## Repository configuration

For the reference deployment, keep real hostnames in the untracked `config/domains.env` on the server. The tracked example intentionally uses placeholders. Populate `HTTP_REDIRECT_DOMAINS` explicitly in the server's local config; the empty default in the repository preserves strict HTTP behavior for new installations.

Do not commit the server's real domains, public IP, credentials, private keys, certificate files or local `domains.env`.
