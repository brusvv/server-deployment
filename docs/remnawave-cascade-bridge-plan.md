# Remnawave cascade bridge — implementation plan

## Goal

Implement and validate the two-node Remnawave topology:

- **VPS A — Entry:** public client entry point. Client-facing protocol is VLESS + XHTTP.
- **VPS B — Panel + Exit:** Remnawave Panel and the egress Xray node share VPS B. This co-location is an intentional topology choice and must be validated against the selected Remnawave/eGamesAPI versions.
- **A → B transport:** dedicated Shadowsocks bridge over TCP and UDP, cipher `chacha20-ietf-poly1305`.

The client-facing XHTTP transport and the inter-node Shadowsocks transport are separate layers and must not be conflated.

## Current decisions

| Item | Decision |
|---|---|
| OS for clean VPS B installation | Ubuntu 24.04 LTS |
| Panel placement | VPS B |
| Exit placement | VPS B |
| Entry placement | VPS A |
| Client protocol/transport | VLESS + XHTTP |
| Inter-node transport | Shadowsocks TCP + UDP |
| Shadowsocks cipher | `chacha20-ietf-poly1305` |
| Panel access | Dedicated hostname protected by IP allowlist (VPN egress IP + recovery IP) |
| Subscription hostname | Separate public hostname |
| Public web ingress on B | HAProxy on TCP 80/443 |
| Web application proxy | Nginx behind HAProxy |
| Bridge port | **TBD** — select after checking provider firewall, current listeners and deployment conventions |
| A/B private network | Not assumed; establish whether a provider private network exists before choosing public-IP transport |

## Known port inventory on the existing B host

The following values are from the repository's historical reference baseline dated 2026-11-18. They describe the previous MTProxyL/HAProxy layout, not the yet-to-be-built Shadowsocks bridge. Revalidate all listeners after the planned OS reinstall.

| Bind | Purpose | Status / note |
|---|---|---|
| `0.0.0.0:80/tcp` | HAProxy HTTP frontend | Historical reference |
| `0.0.0.0:443/tcp` | HAProxy TLS/SNI frontend | Historical reference |
| `127.0.0.1:8444/tcp` | MTProxyL Selfmask frontend | Historical reference |
| `127.0.0.1:15443/tcp` | Telemt MTProto backend | Historical reference; **not** the SS bridge |
| `127.0.0.1:15444/tcp` | MTProxyL WEB TLS frontend | Historical reference |
| `127.0.0.1:15080/tcp` | MTProxyL WEB HTTP backend | Historical reference |
| `127.0.0.1:15481/tcp` | Static/Selfmask backend | Historical reference |
| `127.0.0.1:18080/tcp` | ACME HTTP-01 webroot | Historical reference |
| `127.0.0.1:1443/tcp` | Reserved Xray loopback target | Was not listening in the historical baseline |

The tracked port configuration currently carries the public 80/443 and local service ports above. Do not reuse `15443` for Shadowsocks simply because it appears in the old inventory. The bridge listener must have its own explicit setting (for example, a future `SS_BRIDGE_PORT`) and must be documented consistently on A, B and in firewall checks.

## Routing modes to support

1. **Shadowsocks Full Tunnel** — all eligible outbound traffic from the Entry inbound is forwarded through B. The policy must fail closed if the bridge is unavailable; no silent direct-egress fallback.
2. **Shadowsocks Geo Split** — destination-country/domain rules decide which traffic uses the bridge and which exits directly from A.
3. **Russian Split** — explicit Russian domain/IP rule sets with documented precedence and exceptions. Do not equate an IP geolocation match with the legal or commercial country of a website.
4. **VLESS Route** — optional additional subscription host/route allowing a client to choose the alternate exit. Treat this as a user-selectable routing feature, not as the Shadowsocks transport itself.

Xray routing is first-match-wins. Rule ordering, domain resolution strategy, GeoIP data source/version, private-address handling and catch-all behavior must be tested. CDN/Anycast and stale GeoIP data can produce surprising country matches.

## Security requirements

- Do not commit real domains, public IPs, credentials, UUIDs, Shadowsocks passwords, private keys, certificates, provider tokens or live `.env` files.
- Keep Panel hostname access restricted to the configured allowlist. Subscription hostname remains a separate public endpoint.
- Restrict the B-side Shadowsocks listener at the host/provider firewall to the actual public source IP of A (or use the verified private network if available).
- Do not expose the bridge listener to the entire Internet unless a separately reviewed design explicitly requires it.
- Use distinct secrets for the bridge and client inbounds. Store secrets in root-readable local config only.
- Confirm whether TCP and UDP are both supported end-to-end by the selected Shadowsocks implementation and provider firewall.
- Preserve HAProxy as the single public 80/443 entry point; Nginx handles the static site and Panel reverse proxy behind it.
- No OS reinstall, firewall mutation, service stop, or live routing change is authorized by this plan alone.

## Compatibility caveat: Panel and Exit on one VPS

The eGamesAPI Server Routing helper has a same-box guard in its setup flow. The target design intentionally places Panel and Exit on B, so the stock wizard must not be assumed to support this topology. Review the exact script/version and adapt or configure the Xray objects explicitly. Do not bypass the guard blindly or run the wizard against production.

## Implementation phases

1. **Inventory / preflight:** confirm current A and B identities, public and private addresses, OS, listeners, provider firewall, MTProxyL/HAProxy ownership, Nginx socket and certificate/ACME behavior. Keep secrets redacted.
2. **Port and transport contract:** reserve a dedicated bridge port, specify TCP+UDP behavior, firewall source restriction, health checks and MTU/routing assumptions.
3. **Clean B deployment plan:** pin Remnawave/eGamesAPI/Node versions; confirm supported Panel+Exit co-location; plan HAProxy → Nginx → Panel and separate subscription hostname.
4. **B setup:** install Panel and Exit, configure dedicated SS bridge inbound, verify listener and firewall from A. Do not modify A yet.
5. **A setup:** configure SS outbound to B and client-facing VLESS + XHTTP inbound; test a single controlled profile.
6. **Routing policy:** implement the four modes independently, with first-match order and fail-closed tests.
7. **Validation:** test TCP and UDP, DNS, IPv4/IPv6, direct-vs-bridge egress, B outage behavior, Panel allowlist, subscription access and restart persistence.
8. **Operational docs:** write rollback, secret rotation, health-check and recovery procedures.

## Acceptance criteria

- Bridge listener on B is reachable from A only, for both configured transports.
- A's selected profile exits through B and reports the expected B egress address.
- Full Tunnel has no direct fallback when B or the bridge is unavailable.
- Geo/Russian Split test cases match the documented rule precedence.
- Panel access is denied outside the allowlist; subscription delivery works independently.
- HAProxy remains the only public 80/443 owner; Nginx is loopback/internal behind it.
- Reboot/restart preserves configuration and does not open unintended listeners.
- All tests can be run in check-only mode before any live change.

## Source baseline

- Repository port map: `config/ports.env`.
- Historical reference snapshot: `docs/validated-server-baseline-2026-11-18.md`.
- Branch context: `feature/http-redirect-selfsteal-website`.

This document is a planning baseline, not a claim that either VPS has already been changed or that the bridge is operational.
