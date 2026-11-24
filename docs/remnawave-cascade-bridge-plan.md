# Remnawave cascade bridge — implementation plan

## Goal and topology

Implement and validate the two-node Remnawave topology:

- **VPS A — Entry:** public client entry point. Client-facing transport is VLESS + XHTTP.
- **VPS B — Panel + Exit:** Remnawave Panel and the egress Xray Node share VPS B. This is an intentional co-location decision; the exact Panel/Node version and local control-plane path must be tested.
- **A → B transport:** dedicated Shadowsocks bridge, TCP + UDP, cipher `chacha20-ietf-poly1305`.

The client-facing XHTTP transport and the inter-node Shadowsocks transport are separate layers.

## Decisions and port contract

| Item | Decision |
|---|---|
| Clean OS for B | Ubuntu 24.04 LTS |
| Panel | VPS B |
| Exit Xray Node | VPS B |
| Entry Xray Node | VPS A |
| Client protocol/transport | VLESS + XHTTP on A |
| A → B bridge | Shadowsocks TCP + UDP |
| SS cipher | `chacha20-ietf-poly1305` |
| SS bridge port | **9999/tcp + 9999/udp** |
| SS bridge bind on B | `0.0.0.0` until a provider private-network address is confirmed |
| Panel hostname | Separate hostname, restricted by allowlist (VPN egress IP + recovery IP) |
| Subscription hostname | Separate public hostname |
| Public web ingress on B | HAProxy TCP 80/443 |
| Web application proxy | Nginx behind HAProxy |
| A/B private network | Not assumed; verify provider support before choosing public or private transport |

The bridge port default of **9999** follows eGamesAPI's current Server Routing module (`SR_DEFAULT_PORT=9999`). It is now reserved in the tracked port contract, but has **not** been probed on either live VPS. Before deployment, verify that neither TCP nor UDP 9999 is already occupied and that the provider permits both protocols.

### Historical B port inventory

The following values come from the repository's historical reference baseline dated 2026-11-18. They describe the earlier MTProxyL/HAProxy setup, not the post-reinstall state. Re-audit every listener before reusing them.

| Bind | Purpose | Meaning |
|---|---|---|
| `0.0.0.0:80/tcp` | HAProxy HTTP frontend | Public web entry |
| `0.0.0.0:443/tcp` | HAProxy TLS/SNI frontend | Public TLS/MTProto entry |
| `127.0.0.1:8444/tcp` | MTProxyL Selfmask frontend | Local backend |
| `127.0.0.1:15443/tcp` | Telemt MTProto backend | **Not** the Shadowsocks bridge |
| `127.0.0.1:15444/tcp` | MTProxyL WEB TLS frontend | Local backend |
| `127.0.0.1:15080/tcp` | MTProxyL WEB HTTP backend | Local backend |
| `127.0.0.1:15481/tcp` | Static/Selfmask backend | Local backend |
| `127.0.0.1:18080/tcp` | ACME HTTP-01 webroot | Local backend |
| `127.0.0.1:1443/tcp` | Reserved Xray loopback target | Was not listening in the historical snapshot |
| `0.0.0.0:9999/tcp+udp` | Proposed Shadowsocks bridge listener | New; allow only A as source |

**Do not reuse 15443 for Shadowsocks.** It belongs to the historical MTProto backend. Do not expose Telemt's management API or metrics ports publicly.

### Inter-server and node-management paths

Keep these connections distinct:

| Flow | Destination | Firewall intent |
|---|---|---|
| A → B data plane | B:`9999/tcp+udp` | Allow only A's actual source address (or verified private A address) |
| B Panel → A Remnawave Node control plane | A:`2222/tcp` by eGamesAPI's default node port; verify the actual node record | Allow only B's source address |
| B Panel → B local Node control plane | Local/container/host path on B | Keep internal; do not open public 2222 unless the actual container topology requires it |
| Telegram clients → MTProto on B | Public HAProxy:`443/tcp` | Existing SNI/default-backend design; keep separate from 9999 |
| Telemt on B → Telegram DCs | Outbound TCP to Telegram's DC infrastructure | Must remain reachable; this is not traffic through the A → B bridge |

Do not assume the node control port is 2222 until the actual Panel node record and service configuration are inspected. The eGamesAPI source uses 2222 as its default `NODE_PORT`.

## What the eGamesAPI bridge actually does

The current eGamesAPI Server Routing implementation and the Remnawave server-routing guide establish this model. The eGamesAPI repository itself labels its installer an educational example and warns that it is not for production; use its documented architecture and source as a reference, not as an installer to execute blindly:

1. On the **exit Node**, create or append a Shadowsocks inbound. The reference config uses protocol `shadowsocks`, method `chacha20-ietf-poly1305`, `network: "tcp,udp"`, and an inbound port (9999 by default).
2. Create a service-only Internal Squad containing that inbound and a service user whose SS password is generated/stored by the panel workflow.
3. On the **entry profile**, add an Xray Shadowsocks outbound pointing to the exit address and port with the service user's password.
4. Add ordered routing rules that select the traffic to send through that outbound.
5. Restrict the exit's bridge port to the entry node's real source address. The port is not intended to be an unrestricted public proxy listener.

The service inbound is for terminating the inter-node tunnel; it is not a second public user subscription. The regular users continue connecting to the VLESS inbound on A.

### Required adaptation for Panel + Exit on B

The upstream eGamesAPI `sr_setup()` currently rejects an exit address resolving to the Panel's own public IP (`SR_SAME_BOX`). That guard is intentional for its normal two-machine wizard, so the stock wizard cannot be run unchanged for this topology.

The underlying implementation has a reusable path for an **already registered exit Node**: it can append an SS inbound to the Node's existing profile and activate the new inbound while preserving the Node's other active inbound UUIDs. Our adaptation should use that pattern for the existing local Node on B:

- Verify that the selected exit address is B itself and that the exact expected B Node record is connected to the Panel.
- Read and retain its active Config Profile and inbound UUIDs.
- Check that port 9999 is not already used by any inbound or process.
- Append the service SS inbound to the existing B profile.
- Activate the new inbound in addition to the existing active inbounds. Do not replace the whole profile with an SS-only profile.
- Create/reuse the bridge service squad and service user.
- On A, add the SS outbound and routing rules to the selected Entry profile.
- Apply B's firewall rule for 9999 only after identifying A's real source IP.
- Do not run the upstream remote-node installer against B or install a duplicate `remnanode` container.

This is a deliberate compatibility adapter, not permission to bypass the same-box check blindly. If the local B Node is missing, disconnected, or its profile cannot be read, stop and diagnose instead of switching its profile or installing another Node automatically.

## Routing modes

The eGamesAPI Geo Bridge has two split directions; keep their meaning explicit:

1. **RU direct / everything else through B** (`direct` mode in the eGamesAPI module): Russian IP/domain rules go to A's DIRECT outbound; the catch-all for the selected Entry inbound goes through the SS bridge to B.
2. **RU through B / everything else stays direct on A** (`bridge` mode in the eGamesAPI module): Russian IP/domain rules go through SS; no catch-all is added, so remaining traffic keeps the Entry profile's existing egress.
3. **Full Tunnel (custom policy):** all eligible traffic from the selected Entry inbound goes through B. Must fail closed if the SS bridge is unavailable; no silent direct-egress fallback. This is not the same as either eGamesAPI Geo Bridge direction and requires explicit catch-all and outage tests.
4. **VLESS Route:** optional per-user/per-host exit selection. This is a separate panel feature using `vlessRouteId` in the generated host/UUID and a matching routing rule; it is not the SS transport itself.

Xray routing is first-match-wins. Private-address and block rules, admin rules, geo/domain lists, and catch-all rules must be reviewed in their final merged order. Test domain resolution strategy, GeoIP list source/version, IPv4/IPv6, CDN/Anycast and stale GeoIP cases. Do not treat an IP geolocation result as the legal or commercial country of a website.

## MTProto is a separate service — no Xray bridge pair

MTProto is **not** another A → B service-routing mode:

- Telegram clients connect to the MTProxy/Telemt listener on B and authenticate with a server, port and secret.
- Telemt handles the MTProto session and creates its own outbound connections to the Telegram DC infrastructure.
- There is no separate Remnawave Exit Node, no Shadowsocks bridge, and no Xray outbound object to configure for MTProto.
- In network terms it still has a client-facing listener and outbound traffic. The distinction is that both sides are handled by the one MTProxy process; they are not two separately provisioned Xray inbounds/outbounds.
- On the historical B layout, HAProxy owns public TCP 443 and sends the MTProto/default SNI path to Telemt at `127.0.0.1:15443/tcp`. Retain this only after checking the live HAProxy config and actual Telemt listener. Do not direct clients to port 15443 if it is intentionally loopback-only.
- Telemt API `127.0.0.1:9091` and metrics (if enabled, historically `127.0.0.1:9090`) are management/monitoring endpoints; keep them loopback-restricted.
- Telemt must be able to reach Telegram's DC infrastructure. Do not limit its outbound access to a single guessed DC IP.

The MTProto frontend, its HAProxy SNI routing, secrets and backend port must remain independent from the A → B SS listener on 9999.

## Security requirements

- Do not commit real domains, public IPs, credentials, UUIDs, SS passwords, Telegram proxy secrets, private keys, certificates, provider tokens or live `.env` files.
- Keep Panel hostname access restricted to the configured allowlist. Subscription hostname remains a separate public endpoint.
- Restrict B's bridge listener to A's actual source address (or the confirmed private address). Allow both TCP and UDP because the bridge is configured for both.
- If A and B use public addresses, confirm A's actual egress/source IPv4 before adding the UFW/provider firewall rule; do not assume it matches a DNS name if NAT is involved.
- If a provider private network exists, prefer it only after verifying routing, MTU and firewall support on both sides.
- Keep B's local Panel→Node control plane private. Keep A's Node control port reachable from B only.
- Use separate secrets for the bridge and client inbounds. Keep bridge credentials in root-readable local configuration and out of logs and Git.
- Preserve HAProxy as the single public 80/443 owner; Nginx handles the static site and Panel reverse proxy behind it.
- No OS reinstall, firewall mutation, service stop, profile replacement or live routing change is authorized by this plan alone.

## Implementation phases

1. **Read-only inventory:** run `checks/cascade-audit.sh A` on A and `checks/cascade-audit.sh B` on B. Confirm addresses, provider private-network availability, OS, listener ownership, Node control port, current MTProxyL/HAProxy layout and firewall. Do not paste secrets.
2. **Port and transport contract:** verify 9999 TCP/UDP is free on B; confirm source address and firewall/provider rules; test MTU and TCP/UDP reachability.
3. **Clean B deployment plan:** pin Remnawave/eGamesAPI/Node versions; confirm Panel+local-Node co-location; plan HAProxy → Nginx → Panel and the separate subscription hostname.
4. **B setup:** install Panel and the local Exit Node; add the dedicated SS inbound to the existing Node profile; verify listener and source-restricted firewall from A.
5. **A setup:** register/configure the Entry Node under Panel B; configure the SS outbound to B and client-facing VLESS + XHTTP; test one controlled profile.
6. **Routing policy:** implement the selected Geo Split or Full Tunnel mode independently; VLESS Route is a separate optional feature.
7. **Validation:** test TCP and UDP, DNS, IPv4/IPv6, direct-vs-bridge egress, B outage/fail-closed behavior, Panel allowlist, public subscription access, MTProto reachability and reboot persistence.
8. **Operations:** write rollback, secret rotation, health-check, MTProto config-update and recovery procedures.

## Acceptance criteria

- B's bridge listener on 9999 accepts traffic from A only, for TCP and UDP.
- A's selected profile exits through B and reports B's expected egress address.
- Full Tunnel has no direct fallback when B or the bridge is unavailable.
- Both Geo Split directions match their documented rule order.
- Panel access is denied outside the allowlist; subscription delivery works independently.
- MTProto continues to accept clients through its configured HAProxy/Telemt path and can reach Telegram DCs without using the SS bridge.
- HAProxy remains the only public 80/443 owner; Nginx is internal behind it.
- Reboot/restart preserves configuration and does not open unintended listeners.
- Checks can be run in read-only/check-only mode before any live change.

## Sources and repository baseline

- eGamesAPI Server Routing wiki: https://wiki.egam.es/ru/configuration/server-routing/
- eGamesAPI module implementation: https://github.com/eGamesAPI/remnawave-reverse-proxy/blob/main/src/modules/server_routing.sh
- Remnawave server-routing guide: https://github.com/remnawave/panel/blob/main/docs/learn/server-routing.md
- Telegram MTProxy documentation: https://core.telegram.org/proxy
- Telemt configuration: https://github.com/telemt/telemt/blob/main/config.toml
- Telemt FAQ: https://github.com/telemt/telemt/blob/main/docs/FAQ.ru.md
- Repository port map: `config/ports.env`.
- Historical reference snapshot: `docs/validated-server-baseline-2026-11-18.md`.

This document is a planning baseline, not a claim that either VPS has already been changed or that the bridge is operational.
