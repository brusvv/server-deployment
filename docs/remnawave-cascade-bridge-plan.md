# Remnawave cascade bridge — implementation plan

## Goal and topology

Implement and validate the two-node Remnawave topology:

- **VPS A — Russia / Entry:** Russian public client entry point. Client-facing transport is VLESS + XHTTP.
- **VPS B — abroad / Panel + Exit:** the foreign egress server hosts the Remnawave Panel and its local Xray Node. This is an intentional co-location decision; the exact Panel/Node version and local control-plane path must be tested.
- **A → B transport:** optional dedicated Shadowsocks bridge, TCP + UDP, cipher `chacha20-ietf-poly1305`; enabled explicitly during setup.
- **Primary routing policy (when enabled):** eGamesAPI Geo Bridge `direct` mode — Russian IP/domain destinations leave directly through Russian VPS A; all other traffic from the selected public Entry profile is sent through the SS bridge and leaves via foreign VPS B. When disabled, do not apply the bridge routing rules.

The client-facing XHTTP transport and the inter-node Shadowsocks transport are separate layers. The later VLESS Route option is out of scope for this phase.

## Decisions and port contract

| Item | Decision |
|---|---|
| Clean OS for B | Ubuntu 24.04 LTS |
| Panel | VPS B |
| Exit Xray Node | VPS B |
| Entry Xray Node | VPS A |
| Client protocol/transport | VLESS + XHTTP on A |
| A → B bridge | Optional Shadowsocks TCP + UDP (`SS_BRIDGE_ENABLED`) |
| SS cipher | `chacha20-ietf-poly1305` |
| SS bridge enabled by default | **No**; explicit opt-in (`SS_BRIDGE_ENABLED=1`) |
| SS bridge default port | **9999/tcp + 9999/udp**; configurable (`SS_BRIDGE_PORT`) |
| SS bridge bind on B | `0.0.0.0` until a provider private-network address is confirmed |
| Panel hostname | Separate hostname, restricted by allowlist (VPN egress IP + recovery IP) |
| Subscription hostname | Separate public hostname |
| Public web ingress on B | HAProxy TCP 80/443 |
| Web application proxy | Nginx behind HAProxy |
| A/B private network | Not assumed; verify provider support before choosing public or private transport |

The bridge is **disabled by default**. Set `SS_BRIDGE_ENABLED=1` in `config/ports.env` (or use `./install.sh --configure-bridge`) to include it in the intended deployment. `SS_BRIDGE_PORT` defaults to **9999**, matching eGamesAPI's current `SR_DEFAULT_PORT=9999`, but can be changed during the interactive setup. The selected port is shared by the B-side SS inbound, A-side SS outbound and B-side TCP+UDP firewall allowlist. A valid port is 1–65535 except 2222, which is reserved as the eGamesAPI node-control default; verify that it is free for both TCP and UDP on B and permitted by the provider.

When the bridge is disabled, skip bridge inbound/outbound creation, bridge firewall rules and Geo Bridge routing changes. Do not activate the `direct` catch-all policy without a working SS outbound. If an already deployed bridge is being disabled, first revert/remove the Entry routing rules and SS outbound, then disable the B-side inbound and remove its source-restricted firewall rule; do not simply stop the Exit listener while the Entry profile still routes traffic into it.

The setup wizard records the local target settings and backs up `config/ports.env`. The managed eGamesAPI adapter below consumes this file at runtime: it blocks new Geo Bridge setup/attachment while disabled, forces the configured port while enabled, and pins Geo Bridge routing to `direct`. Changing the port while a bridge is active does not migrate its existing inbound/outbound/firewall state; run eGamesAPI Teardown first, then set the new port and create the bridge again. The actual Remnawave and firewall operations remain in eGamesAPI and require its explicit confirmation.

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
| `0.0.0.0:$SS_BRIDGE_PORT/tcp+udp` (default 9999; only when enabled) | Proposed Shadowsocks bridge listener | New; allow only A as source |

**Do not reuse 15443 for Shadowsocks.** It belongs to the historical MTProto backend. Do not expose Telemt's management API or metrics ports publicly.

### Inter-server and node-management paths

Keep these connections distinct:

| Flow | Destination | Firewall intent |
|---|---|---|
| A → B data plane | B:`$SS_BRIDGE_PORT/tcp+udp` (when enabled) | Allow only A's actual source address (or verified private A address) |
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
- Check that configured `SS_BRIDGE_PORT` is not already used by any inbound or process.
- Append the service SS inbound to the existing B profile.
- Activate the new inbound in addition to the existing active inbounds. Do not replace the whole profile with an SS-only profile.
- Create/reuse the bridge service squad and service user.
- On A, add the SS outbound and routing rules to the selected Entry profile.
- Apply B's firewall rule for the configured `SS_BRIDGE_PORT` only after identifying A's real source IP.
- Do not run the upstream remote-node installer against B or install a duplicate `remnanode` container.

This is a deliberate compatibility adapter, not permission to bypass the same-box check blindly. If the local B Node is missing, disconnected, or its profile cannot be read, stop and diagnose instead of switching its profile or installing another Node automatically.

#### Narrow eGamesAPI same-box compatibility patch

The inspected eGamesAPI module rejects an Exit host whose resolved public IPv4 equals the Panel public IPv4, before it reaches the existing-node reuse path. The repository patcher replaces only that exact guard with a narrower check:

- The same-box exception is accepted only if `sr_find_node_by_host "$host"` finds the already registered Node, its active profile UUID is present, and `isConnected` is true.
- If the module has changed, the Node cannot be matched by the selected Exit host, or the Node is disconnected, the patcher/setup remains fail-closed.
- It does not install a Node, add an inbound, switch a profile, alter a firewall, or modify the Panel API. Those remain separate, visible eGamesAPI wizard actions.
- The patcher is version/context guarded, makes a timestamped backup, validates the resulting module with `bash -n`, and requires an explicit typed confirmation.

On VPS B, locate the actual cached module path and run:

    sudo python3 checks/egamesapi-local-exit-compat.py --check /absolute/path/to/server_routing.sh
    sudo python3 checks/egamesapi-local-exit-compat.py --apply /absolute/path/to/server_routing.sh

If the Node record uses a private Docker gateway address that does not match the selected Exit host, the patch intentionally refuses to enable the exception. In that case inspect the actual Node `address` and adapt the lookup based on the live topology; do not weaken the check to a blanket bypass. eGamesAPI updates may replace the cached module, so rerun the check after updating eGamesAPI.

The same-box patch context was verified against the eGamesAPI Server Routing source at commit `93e6631aae5f7bff28eadfc45faab43150cc22c6`; this does not pin or install that upstream revision.

#### Managed bridge toggle and port adapter

The second adapter patch connects `SS_BRIDGE_ENABLED` and `SS_BRIDGE_PORT` to eGamesAPI's own Server Routing workflow. Apply it only after the same-box compatibility patch:

```bash
sudo bash checks/egamesapi-bridge-adapters.sh --check --config-file /opt/server-deployment/config/ports.env --module /absolute/path/to/server_routing.sh

sudo bash checks/egamesapi-bridge-adapters.sh --apply --config-file /opt/server-deployment/config/ports.env --module /absolute/path/to/server_routing.sh
```

Use the actual checkout path if `SD_INSTALL_DIR` differs from `/opt/server-deployment`. The combined runner checks both source contexts on a temporary copy, then applies the same two patchers in order after one typed `APPLY` confirmation. It creates separate timestamped backups and verifies both patches after installation. This patch:

- Reads only the two bridge settings from the selected `config/ports.env`; it does not source or execute that file.
- Loads the selected port when eGamesAPI setup starts and rejects a different port at its prompt, preventing inbound/outbound/firewall port drift.
- Bypasses eGamesAPI’s interactive Geo Bridge mode picker and pins the policy to `direct`; attaching another Entry profile is refused if its saved bridge state has any other mode.
- Blocks `sr_setup` and `sr_attach_profile` while `SS_BRIDGE_ENABLED=0`.
- Leaves `sr_teardown` available while disabled, so the existing bridge can be removed safely.
- Requires the already patched same-box guard, and makes no API request or live change itself.

**Disable sequence:** open `Расширения ноды → Серверный роутинг (мост)`, select the configured Geo Bridge and run its Teardown action first. eGamesAPI removes the bridge routes/outbound from the attached Entry profiles, deletes its service user and squad, and removes the recorded UFW allow rules. Its current teardown deliberately retains the Exit Node and Config Profile; it does not automatically remove the SS inbound from that profile. After teardown, inspect B's active Config Profile and, only after identifying the bridge inbound by its dedicated tag/UUID, remove that inbound while preserving every existing user-facing inbound. Do not delete or replace the whole profile. Only after teardown succeeds should `SS_BRIDGE_ENABLED` be set to `0`. This avoids leaving Entry traffic pointed at a stopped Exit listener. The adapter's off switch blocks new setup/attachment; it is not a remote cleanup command.

If the eGamesAPI module changes, both patchers fail closed on unknown source context. Recheck and reapply them only after reviewing the changed upstream module.


## Primary routing policy

When `SS_BRIDGE_ENABLED=1`, use eGamesAPI Geo Bridge **`direct` mode**. This is the correct direction for a Russian Entry and a foreign Exit. When the bridge is disabled, do not apply these routing changes and leave the Entry profile routing untouched:

1. `geoip:ru` destinations use the Entry Node's `DIRECT` outbound and leave from Russian VPS A.
2. `geosite:category-ru` destinations also use `DIRECT` on A.
3. The selected public profile's remaining traffic is caught by an `inboundTag` rule and sent to the Shadowsocks outbound; it leaves through foreign VPS B.

Do **not** select eGamesAPI's `bridge` mode for this topology: that mode sends RU destinations through the bridge and leaves the rest on A. The eGamesAPI module's own mode-selection comment distinguishes these two directions.

This policy is a geographic split, not a literal full tunnel. A later request to force even Russian destinations through B would require a separately designed Full Tunnel policy and outage tests. **VLESS Route** is another separate feature: it adds a selectable per-user/per-host exit using `vlessRouteId`; it is explicitly deferred until the primary bridge is stable.

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

The MTProto frontend, its HAProxy SNI routing, secrets and backend port must remain independent from the A → B SS listener on the selected `SS_BRIDGE_PORT`.

## Security requirements

- Do not commit real domains, public IPs, credentials, UUIDs, SS passwords, Telegram proxy secrets, private keys, certificates, provider tokens or live `.env` files.
- Keep Panel hostname access restricted to the configured allowlist. Subscription hostname remains a separate public endpoint.
- When enabled, restrict B's bridge listener to A's actual source address (or the confirmed private address) for both TCP and UDP. When disabled, do not create the listener or its firewall rule.
- If A and B use public addresses, confirm A's actual egress/source IPv4 before adding the UFW/provider firewall rule; do not assume it matches a DNS name if NAT is involved.
- If a provider private network exists, prefer it only after verifying routing, MTU and firewall support on both sides.
- Keep B's local Panel→Node control plane private. Keep A's Node control port reachable from B only.
- Use separate secrets for the bridge and client inbounds. Keep bridge credentials in root-readable local configuration and out of logs and Git.
- Preserve HAProxy as the single public 80/443 owner; Nginx handles the static site and Panel reverse proxy behind it.
- No OS reinstall, firewall mutation, service stop, profile replacement or live routing change is authorized by this plan alone.

## Installer configuration

The bridge settings live in `config/ports.env`:

```bash
SS_BRIDGE_ENABLED="0"   # 0 = disabled, 1 = enabled
SS_BRIDGE_PORT="9999"   # TCP + UDP; default follows eGamesAPI
```

Run `./install.sh --configure-bridge` for the interactive toggle and port prompt. A full interactive `./install.sh --run` also asks before starting the stages. `--check` and non-interactive runs never prompt and use the stored settings. The wizard validates the port, writes a local timestamped backup, and makes no server-side changes.

This is a configuration contract and preflight gate, not automated bridge provisioning. Remnawave API/profile mutation and firewall application remain separate, explicitly reviewed integration steps.

## Implementation phases

1. **Read-only inventory:** run `checks/cascade-audit.sh A` on A and `checks/cascade-audit.sh B` on B. Confirm each server's public/source address, provider private-network availability, OS, listener ownership, Node control port, current MTProxyL/HAProxy layout and firewall. Do not paste secrets.
2. **Port and transport contract:** when enabled, verify the configured `SS_BRIDGE_PORT` is free for TCP and UDP on B; identify A's real egress/source address (including NAT); confirm provider/UFW rules; test MTU and both transport protocols.
3. **B deployment:** install the Panel and local Exit Node on foreign VPS B. Preserve the intended HAProxy → Nginx → Panel ownership of web ports and keep the subscription hostname separate. Pin and review upstream versions before execution.
4. **A registration:** register the Russian Entry Node A in Panel B, keep its control-plane port reachable from B only, and confirm the Node is connected with the intended public VLESS + XHTTP inbound/profile.
5. **Local Exit adapter:** confirm B's Exit Node already exists and is connected; configure SSH access to B for the eGamesAPI remote-exec helper; run the guarded same-box compatibility patch above. Do not use the new-node/install or profile-switch path to replace a working B Node.
6. **Create the primary Geo Bridge (only when `SS_BRIDGE_ENABLED=1`):** in `Расширения ноды → Серверный роутинг (мост)`, choose B as the Exit, use the configured `SS_BRIDGE_PORT` (default 9999), choose `direct` mode, and attach the intended public Entry profile on A. When the existing B Node has active user-facing inbounds, choose the add-inbound option so its existing active inbound UUIDs remain enabled. If disabled, skip this phase and leave routing unchanged.
7. **Validate:** test TCP and UDP, DNS, IPv4/IPv6, RU-direct vs non-RU-through-B egress, B outage behavior, Panel allowlist, public subscription access, MTProto reachability and reboot persistence. Confirm the bridge port on B is source-restricted to A.
8. **Operations:** document rollback, bridge-secret rotation, health checks, eGamesAPI update/re-patch, MTProto config-update and recovery procedures.

VLESS Route and a custom Full Tunnel are not part of this implementation phase.

## Acceptance criteria

- When enabled, B's bridge listener on the configured `SS_BRIDGE_PORT` accepts traffic from A only, for TCP and UDP; when disabled, no bridge listener or allow rule is created.
- When enabled, Russian destinations from the selected public Entry profile leave through A.
- When enabled, non-Russian destinations from the selected public Entry profile leave through B and report B's expected egress address.
- When enabled, if B or the bridge is unavailable, the non-Russian path does not silently fall back to direct egress on A; RU-direct destinations remain local to A.
- The eGamesAPI same-box exception works only for the already registered, connected local B Node; unknown or disconnected Nodes remain rejected.
- Existing active inbounds on B remain active when the SS inbound is appended.
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
