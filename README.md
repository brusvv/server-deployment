# server-deployment

Safety-first deployment helpers and integration adapters for a Remnawave two-node cascade, with optional MTProxyL/Telemt, HAProxy and Cloudflare WARP over Xray MASQUE.

> **Status: early development / integration scaffold.** This repository is not a one-command installer for the complete A → B topology. It provides preflight checks, host preparation, guarded integrations, configuration adapters and validation. Upstream eGamesAPI and MTProxyL installers remain operator-supplied, reviewed integration points. Remnawave profile changes for the Shadowsocks bridge are performed through the eGamesAPI Server Routing workflow, not automatically by this repository.

## Branch and scope

This README describes **`feature/remnawave-fingerprint-hardening`**. It supersedes the older HTTP-redirect/SelfSteal feature-branch instructions.

The target topology is:

| Host | Role | Main responsibilities |
|---|---|---|
| **VPS A — Russia / Entry** | Client entry | VLESS + XHTTP inbound; registered Remnawave Node; optional Shadowsocks outbound to B |
| **VPS B — abroad / Panel + Exit** | Control plane and foreign egress | Remnawave Panel + its local Xray Node; optional Shadowsocks inbound from A; MTProxyL/Telemt and HAProxy |

The Panel and Exit Node intentionally share VPS B. The A → B transport is a separate, optional Shadowsocks bridge. The client-facing VLESS + XHTTP transport and the inter-node Shadowsocks transport are different layers.

### Traffic model

When the bridge is enabled, the intended eGamesAPI Geo Bridge policy is **`direct`**:

- Russian IP/domain destinations leave directly through VPS A.
- Other traffic selected by the Entry profile is sent through the Shadowsocks bridge and exits through VPS B.
- Telegram MTProto traffic is handled separately by Telemt on B; it does not traverse the A → B Shadowsocks bridge.

This is a geographic split, not a full tunnel. The bridge is disabled by default. Do not apply bridge routing rules while it is disabled or before the B-side inbound, A-side outbound and source-restricted firewall rule are working.

**VLESS Route is deferred** and is not part of this implementation phase.

## What the repository does

- Read-only inventory of the A/B servers with `checks/cascade-audit.sh`.
- Preflight validation of supported OS, configured domains and network ports.
- Optional installation of base system packages and creation of state/backup directories.
- Pinned eGamesAPI installer execution for Remnawave Panel + local Node (and the subscription page/reverse proxy bundled by its combined mode), post-install container checks and guarded Nginx version hardening (`server_tokens off;`).
- Remnawave network-adapter guidance for the intended Xray loopback listener; it does not mutate a Config Profile.
- Explicit hand-off to a reviewed local MTProxyL installer.
- A guarded HAProxy adapter that edits the active MTProxyL custom config, validates the candidate, backs up the active file and reloads the matching service.
- Optional HTTP → HTTPS redirects and ACME HTTP-01 routing in the HAProxy adapter.
- Guarded eGamesAPI patchers for the Panel + local Exit topology and the optional bridge toggle/port policy.
- Optional Cloudflare WARP over Xray MASQUE outbound management through Remnawave Config Profiles.
- Project-managed backup create/list/restore actions.

### What it does not do automatically

- It does not reinstall the OS or clean an existing VPS.
- It does not install a second independent Remnawave stack.
- The repository pins the eGamesAPI installer checkout to one reviewed commit after explicit confirmation; however, that upstream script still retrieves some external runtime dependencies dynamically (including Docker's official install script and fallback module/language files from its `main` branch). MTProxyL remains an operator-supplied local installer.
- It does not automatically create the A/B Shadowsocks inbound/outbound, service user/squad, routing rules or firewall allowlist. Those operations remain in the eGamesAPI Server Routing workflow and require operator confirmation.
- It does not automatically edit Remnawave `customResponseHeaders` or subscription-page branding; remove/replace the dummy `support-url` and customize the `profile-title` value manually in Panel settings.
- It does not automatically mutate the Remnawave inbound for the network adapter.
- It is not a standalone HAProxy installer. The HAProxy stage expects the MTProxyL-managed custom HAProxy config and service to exist and be active.
- It does not configure the planned SelfSteal website choices.

## Important defaults

| Setting | Default | Meaning |
|---|---:|---|
| `SS_BRIDGE_ENABLED` | `0` | A → B Shadowsocks bridge disabled |
| `SS_BRIDGE_PORT` | `9999` | Proposed bridge port, TCP + UDP |
| `SS_BRIDGE_NETWORK` | `tcp,udp` | Bridge transport |
| `SS_BRIDGE_METHOD` | `chacha20-ietf-poly1305` | Shadowsocks cipher |
| `XRAY_LOOPBACK_HOST` | `127.0.0.1` | HAProxy → Xray backend host |
| `XRAY_LOOPBACK_PORT` | `1443` | HAProxy → Xray backend port |
| `ACME_WEBROOT_HOST:PORT` | `127.0.0.1:18080` | Optional ACME HTTP-01 webroot |
| `WARP_MASQUE_TRANSPORT` | `h2` | WARP transport; HTTP/2 over TCP/443 |

The bridge port must be free for both TCP and UDP on B and permitted by the provider. The default port is not assumed to be free. Port 2222 is excluded by the bridge settings validator because it is the eGamesAPI node-control default; verify the actual Node control port before deployment.

Historical MTProxy backend `127.0.0.1:15443/tcp` is **not** the Shadowsocks bridge. Do not reuse it for the bridge.

## Before deployment: audit both VPSs

Run the read-only inventory separately on each host:

```bash
sudo bash checks/cascade-audit.sh A
sudo bash checks/cascade-audit.sh B
```

Use the matching role argument on the matching VPS. The audit reports OS/resources, interfaces/routes, listening sockets, relevant systemd units, Docker names/images/status/ports and firewall state.

On VPS B the audit also checks `/opt/remnawave/nginx.conf` for `server_tokens off;`, validates the `remnawave-nginx` config with `nginx -t`, and prints a manual checklist for Remnawave subscription response headers. It does not query Panel credentials or subscription UUIDs.

The audit deliberately does not read secrets, service environment variables, Docker environment variables or process command lines. Its output can still contain public/private IP addresses, hostnames and firewall source addresses. Review and redact it before sharing.

Before changing an existing server, save the audit output and make an independent backup of important application data and configuration. The project backup is not a substitute for a full VPS/provider snapshot.

## Requirements

- Debian or Ubuntu; other distributions are not supported by preflight.
- Root access for execution stages.
- Python 3 (installed by the System stage), Bash and the other utilities installed by the System stage.
- DNS records for the configured domains.
- Public TCP 80/443 available when deploying the B-side web/HAProxy stack.
- Network access to GitHub for the pinned eGamesAPI source; an operator-reviewed local MTProxyL installer if that optional component is selected.
- For the A → B bridge: verified A source/egress address, B listener port availability and provider/firewall support for TCP and UDP.

Do not assume A and B have a private network. Verify provider support, routes and MTU before choosing private addressing. If using public addresses, identify A's actual source address as seen by B (including NAT).

## Install this branch

The bootstrap defaults to `main`. To bootstrap this feature branch from a terminal, set `SD_GIT_REF=feature/remnawave-fingerprint-hardening`; the bootstrap validates that an existing checkout is already on the requested branch and will not switch it automatically. For a reproducible deployment, prefer a reviewed local checkout pinned to a commit.

```bash
apt-get update
apt-get install -y git

git clone --depth 1 \
  --branch feature/remnawave-fingerprint-hardening \
  https://github.com/brusvv/server-deployment.git \
  /opt/server-deployment

cd /opt/server-deployment
```

Create the host-specific domain config:

```bash
cp config/domains.env.example config/domains.env
nano config/domains.env
```

Set real hostnames you control:

- `REMNAWAVE_SNI_DOMAINS`: space-separated SNI hostnames routed to Xray.
- `WEB_DOMAIN`: the separate WEB hostname.
- `HTTP_REDIRECT_DOMAINS`: optional HTTP → HTTPS policy. Leave empty for strict behavior, list hostnames for an allowlist, or set exactly `all` to redirect every HTTP request handled by HAProxy.

The example hostnames are placeholders and will fail preflight. If `config/domains.env` already exists, preserve it; do not overwrite it with the example file.

Review `config/ports.env` and `config/services.env` before running anything. Keep `SS_BRIDGE_ENABLED="0"` until the A/B bridge is deliberately being provisioned.

Run the read-only preflight:

```bash
sudo ./install.sh --check
```

Check-only is the default. It does not install packages, run external installers, register WARP or mutate a Remnawave Config Profile.

## Installation workflow

When started with no arguments in an interactive terminal, `./install.sh` opens the installation menu:

1. **Обычная установка Remnawave** — eGamesAPI combined Panel + local Node mode (also includes its subscription page/reverse proxy); no additional repository components. Upstream warns this combined mode is not recommended for production.
2. **Remnawave + дополнительные компоненты** — the extended single-host profile with the network adapter, MTProxyL, HAProxy integration and optional WARP/MASQUE.
3. **Каскад Remnawave** — asks whether this machine is VPS A (Entry) or VPS B (Panel + Exit).

The selected profile and its stage list are shown before confirmation. **Yes** starts it, **No** returns to the main menu, and **Exit** closes the installer. No system changes are made before the confirmation. Required system preparation and eGamesAPI installation have their own confirmations and fail closed on refusal. Optional stages use a distinct skipped status. Non-interactive no-argument execution remains check-only; explicit CLI commands continue to work as before.

**Reproducibility limitation:** pinning the eGamesAPI installer commit does not pin all runtime artifacts. The pinned combined installer generates Docker Compose references including `remnawave/backend:3`, `remnawave/subscription-page:latest`, `remnawave/node:latest`, `postgres:18.6`, `valkey/valkey:9.1.2-alpine` and `nginx:1.30`; these are tags, not immutable digests. eGamesAPI also sets `SOURCE_BRANCH=main` for fallback downloads when a bundled `src/` module or language file is missing. The local bundled `src/` takes precedence, but the commit pin alone does not guarantee every fallback is pinned. The container audit records actual image IDs/digests for each deployment; before claiming reproducible production deployment, freeze and review the exact image digests and any fallback downloads.


The profiles intentionally reflect current implementation boundaries. The standard Remnawave profile runs preflight, backup, required base-package preparation, pinned eGamesAPI installation, automatic Nginx version hardening and validation. eGamesAPI is pinned to commit `93e6631aae5f7bff28eadfc45faab43150cc22c6` (v3.8.4); the installer source and its bundled `src/` modules are checked out together. In eGamesAPI choose **1 → 1** to install Panel + Node on this host. Its combined mode also installs the subscription page and reverse-proxy components. **Important:** eGamesAPI itself says this combined Panel + Node mode is not recommended for production; it recommends separate Panel-only / Node-only modes. The extended profile adds the network adapter, optional MTProxyL, HAProxy integration and optional WARP/MASQUE. VPS A currently performs preflight, a local backup and base-package preparation only; it does not install/register the Remnawave Node or create its VLESS inbound. VPS B owns the Panel/Exit and optional MTProxyL/HAProxy path. Neither cascade profile automatically creates the live Shadowsocks inbound/outbound, service user/squad, routing rules or firewall allowlist.

The repository stages are deliberately separated:

1. **Preflight** — checks OS, configured domains, DNS and ports.
2. **System** — after confirmation, installs base packages and creates state/log/backup directories.
3. **eGamesAPI + Remnawave** — fetches a pinned eGamesAPI commit, validates the Git commit, script version and Bash syntax, then runs its interactive installer. For the standard/B-side single-host flow select menu item 1, then item 1. The stage runs `checks/remnawave-container-audit.sh` after eGamesAPI exits. It requires the Panel, database, cache, Nginx, subscription-page and local Node containers to be running; database, cache and Panel health checks must report healthy. It records each container's image reference, local image ID and available repository digest. It then runs `checks/remnawave-nginx-hardening.sh --apply`: backs up `/opt/remnawave/nginx.conf`, adds `server_tokens off;` idempotently, validates with `nginx -t` inside `remnawave-nginx` and reloads only that container. On validation/reload failure it restores the backup and fails the stage.
4. **Network adapter** — reports the intended Xray loopback change and fallback expectations. It does not update a Remnawave profile.
5. **MTProxyL** — runs only a local reviewed installer supplied through `MTPROXYL_INSTALLER_LOCAL`.
6. **HAProxy** — integrates with an already active MTProxyL custom HAProxy config; it does not install MTProxyL or HAProxy.
7. **Validation** — checks domains, ports and services.
8. **WARP MASQUE** — optional interactive setup; the default answer is No.

Run logs are stored under `/var/log/server-deployment` with a `0700` directory and `0600` files; child-stage output and exit failures are captured. eGamesAPI and MTProxyL interactive installer output is sent directly to the controlling terminal and excluded from persistent logs because it may contain generated credentials.

The direct command `sudo ./install.sh --run` retains the legacy bridge-settings prompt and saves the selected settings locally. Its full stage sequence now creates the project backup immediately after preflight and before system/package changes. The menu-driven profiles do not toggle this setting automatically. Run `sudo ./install.sh --configure-bridge` separately when preparing the B-side bridge configuration. That wizard does **not** create or remove live bridge components.

### Run modes and individual stages

```bash
# Read-only checks (default)
sudo ./install.sh --check

# Run the full interactive stage sequence
sudo ./install.sh --run

# Run a single stage
sudo ./install.sh --run --stage preflight
sudo ./install.sh --run --stage system
sudo ./install.sh --run --stage remnawave
sudo ./install.sh --run --stage adapter
sudo ./install.sh --run --stage mtproxyl
sudo ./install.sh --run --stage haproxy
sudo ./install.sh --run --stage validate
sudo ./install.sh --run --stage backup
sudo ./install.sh --run --stage warp-masque
```

Available stages: `preflight`, `system`, `remnawave`, `adapter`, `mtproxyl`, `haproxy`, `validate`, `backup`, `warp-masque`.

The eGamesAPI stage checks out the pinned commit listed above and uses its bundled `src/` files when present. The pinned upstream script sets `SOURCE_BRANCH=main` for missing-module/language fallbacks and may download external runtime scripts; the commit pin therefore does not freeze every dependency. The optional MTProxyL stage still accepts a reviewed local installer:

```bash
export MTPROXYL_INSTALLER_LOCAL=/root/installers/reviewed-mtproxyl-installer.sh
```

If MTProxyL, HAProxy integration or WARP/MASQUE is declined or unavailable, the stage is reported as **skipped**. A skipped optional stage is not reported as completed. Declining required system preparation or eGamesAPI installation stops the profile.

## A/B Shadowsocks bridge

### Settings

The bridge settings are in `config/ports.env`:

```bash
SS_BRIDGE_ENABLED="0"
SS_BRIDGE_BIND="0.0.0.0"
SS_BRIDGE_PORT="9999"
SS_BRIDGE_NETWORK="tcp,udp"
SS_BRIDGE_METHOD="chacha20-ietf-poly1305"
```

Use the local wizard to record the intended state:

```bash
./install.sh --configure-bridge
```

It validates the port, writes a timestamped backup of `config/ports.env` and changes only that local file. It does not create an inbound/outbound, change a firewall or modify a Remnawave profile. A full interactive `./install.sh --run` asks the same question before running all stages. Check-only and non-interactive runs never prompt.

Changing the configured port while a bridge is active does not migrate its existing inbound, outbound or firewall state. Run eGamesAPI Teardown first, then recreate the bridge with the new port. Setting the local flag to `0` is not a teardown command.

### eGamesAPI adapters for Panel + local Exit on B

The upstream eGamesAPI Server Routing module normally rejects an Exit host that resolves to the same public IP as the Panel. This topology intentionally places Panel + Exit on B. The repository includes a narrow compatibility patch that permits the same-box case only when the matching Node already exists, is connected and has an active profile. It does not install a Node or change Panel objects.

On B, locate the actual module:

```bash
sudo find /opt/remnawave -type f -name server_routing.sh -print
```

Check and apply the same-box compatibility patch:

```bash
sudo python3 checks/egamesapi-local-exit-compat.py --check /absolute/path/to/server_routing.sh
sudo python3 checks/egamesapi-local-exit-compat.py --apply /absolute/path/to/server_routing.sh
```

Then check and apply the bridge toggle/port/direct-mode adapters:

```bash
sudo bash checks/egamesapi-bridge-adapters.sh \
  --check \
  --config-file /opt/server-deployment/config/ports.env \
  --module /absolute/path/to/server_routing.sh

sudo bash checks/egamesapi-bridge-adapters.sh \
  --apply \
  --config-file /opt/server-deployment/config/ports.env \
  --module /absolute/path/to/server_routing.sh
```

Use the real checkout path if it is not `/opt/server-deployment`. The combined `--apply` flow requires typing `APPLY`, creates timestamped backups and verifies both patches. It modifies only the eGamesAPI module file; it does not create a Node, profile, inbound, service user/squad, firewall rule or live route.

If either patcher reports that the installed source differs from the expected context, stop. Do not manually bypass the same-box guard. Recheck compatibility after eGamesAPI updates because an upstream update may replace its cached module.

### Create and remove the live bridge

After the adapters are installed and verified, use eGamesAPI's own workflow under **Node extensions → Server Routing (bridge)**:

- Select B as the Exit and the intended Entry profile on A.
- Use the dedicated Shadowsocks bridge inbound on B and outbound/routing on A.
- Use the `direct` Geo Bridge policy for the Russia-Entry → foreign-Exit topology.
- Restrict B's bridge port to A's actual source address for both TCP and UDP.
- Confirm the bridge inbound, Entry outbound, routing and firewall state before sending user traffic through it.

The adapters force the configured bridge port and `direct` mode, and block new setup/attachment while the bridge is disabled. They do not perform the live eGamesAPI workflow for you.

**Teardown order matters.** Use eGamesAPI Teardown first to remove Entry routes/outbound, service user/squad and recorded UFW rules. Then inspect B's active Config Profile and remove only the dedicated bridge inbound, preserving every existing user-facing inbound. Only after teardown should you set `SS_BRIDGE_ENABLED="0"`. Do not simply stop the B listener while A still routes traffic through it.

See [the detailed cascade plan](docs/remnawave-cascade-bridge-plan.md) for the topology, routing order, firewall model, same-box compatibility rationale and implementation phases.

## MTProxyL, HAProxy and HTTP redirects

MTProxyL/Telemt is a separate service on B. Its Telegram traffic is not part of the A → B Shadowsocks bridge.

The HAProxy stage is an **adapter** for the active MTProxyL-managed custom configuration. It requires:

- The configured HAProxy config, binary and MTProxyL settings file to exist.
- `FRONT_SERVER='haproxy'` and `NGINX_CUSTOM_ENABLED='true'` in MTProxyL settings.
- The configured systemd service to reference the same HAProxy config and binary.
- The service to be active before a live reload.

It discovers the existing port layout and changes only managed bind/server directives, Remnawave SNI routing and explicitly enabled HTTP/ACME rules. It validates the candidate with the configured HAProxy binary and creates a timestamped backup before replacement. If reload fails, it restores the previous file and attempts to reload it.

In interactive run mode:

- Option 1 adopts the port layout discovered from the active config.
- Option 2 allows internal backend ports to be entered manually.
- Option 0 exits without changes.

If a backend is not ready, Xray is not listening on the configured loopback endpoint, or a requested internal bind is occupied, the stage saves a root-only pending plan, returns a skipped status and does not replace or reload the active config. The dispatcher reports HAProxy as skipped rather than successful. Public HTTP/HTTPS ports are retained from discovery.

### HTTP → HTTPS and ACME

Redirects are opt-in through `HTTP_REDIRECT_DOMAINS` in `config/domains.env`:

- Only explicitly listed Host values receive same-host HTTP → HTTPS redirects.
- Unknown Host values receive 404.
- Set `HTTP_REDIRECT_DOMAINS="all"` to redirect every HTTP request handled by the HAProxy HTTP frontend, regardless of its Host value.
- ACME HTTP-01 requests under `/.well-known/acme-challenge/` bypass redirects and are sent to the configured webroot backend.
- The default webroot endpoint is `127.0.0.1:18080` (`ACME_WEBROOT_HOST` / `ACME_WEBROOT_PORT`).
- The webroot service must already be listening when redirects are enabled.

The HAProxy stage does not install Certbot, issue certificates or rewrite existing certificate-renewal configuration. Leave `HTTP_REDIRECT_DOMAINS` empty to retain the default strict HTTP behavior.

The current HAProxy adapter sends hostnames in `REMNAWAVE_SNI_DOMAINS` to the Xray backend. It does not implement separate HTTPS reverse-proxy routes for the Panel or Subscription Page. Do not repurpose those SNI names for web applications until a separate route has been implemented and tested.

## Optional Cloudflare WARP over Xray MASQUE

WARP/MASQUE is an optional Xray outbound. It is independent of HAProxy, MTProxyL and the A → B Shadowsocks bridge.

The install flow offers optional setup; the default is No. It can also be managed later:

```bash
sudo ./manage.sh
```

The manager supports:

- Remnawave Panel API connection.
- WARP device registration/re-registration.
- Adding/updating and disabling the managed outbound in a selected Config Profile.
- Routing policy: outbound only, unmatched traffic, or selected domains.
- Switching between HTTP/2 (`h2`) and HTTP/3 (`h3`).
- Status and endpoint probe.

Important limitations and safeguards:

- Xray-core **26.10.31 or newer** is required by the current configuration guard.
- HTTP/2 uses TCP/443; HTTP/3 requires outbound UDP/443.
- WARP does not provide a selectable country exit and is not an anonymity service.
- Adding the outbound alone does not redirect user traffic; routing must be selected explicitly.
- Profile changes require exactly one attached Node and a typed confirmation that it is the local VPS Node. The manager cannot independently verify a Node's physical host identity.
- A full Config Profile backup is created before each profile update; the result is read back and checked.
- API credentials and private keys are stored outside the repository with restrictive permissions. Never commit `config/warp-masque.env`, state files or credentials.
- The consumer registration API is undocumented/reverse-engineered and may change. Registration requires explicit acknowledgement of Cloudflare's Terms. Re-registering creates a new device; it does not automatically revoke the previous registration.
- The endpoint probe is not a complete egress test. Verify the actual Xray routing and observed public egress separately.

Optional overrides can be placed in `config/warp-masque.env`; start from `config/warp-masque.env.example`. Check-only mode does not register a device or mutate a Remnawave profile.

## Configuration files

| File | Purpose |
|---|---|
| `config/domains.env` | Host-specific SNI, WEB and optional redirect domains; create locally from the example |
| `config/ports.env` | Public/internal ports and optional A/B bridge settings |
| `config/services.env` | Service paths, systemd unit, binary and process-name hints |
| `config/warp-masque.env` | Optional WARP overrides; create locally from the example |

Do not commit live `.env` files, domain inventories that reveal infrastructure, public IPs, credentials, UUIDs, Shadowsocks passwords, Telegram secrets, API tokens, private keys or certificates.

## Backups

The project backup stage supports:

- Create: `sudo ./install.sh --run --stage backup`
- List: `sudo env SD_ROOT=/opt/server-deployment bash /opt/server-deployment/modules/07-backup.sh list`
- Restore: `sudo env SD_ROOT=/opt/server-deployment bash /opt/server-deployment/modules/07-backup.sh restore /var/backups/server-deployment/archive.tar.gz`

Use the actual checkout path if it is not `/opt/server-deployment`. Restoration requires confirmation and may overwrite existing files. The default backup directory is `/var/backups/server-deployment`. Archives are created with restrictive permissions. Review the archive contents before restoring. Maintain a separate provider snapshot or off-server backup for critical data.

## Single-VPS testing

The repository can be checked and its local components can be tested on one VPS, with `SS_BRIDGE_ENABLED="0"`. This is useful for validating the host setup, MTProxyL/HAProxy integration and optional WARP manager.

A single VPS is **not** a functional A → B cascade test. It cannot validate the geographic split, cross-server transport, source-restricted firewall, foreign egress address or independent failure behavior. Do not describe a loopback/two-process test as proof of the real cascade.

## Development and tests

Run the repository test suite from the checkout:

```bash
bash tests/shellcheck.sh
```

CI runs shell checks, Python compilation, local regression tests and a pseudo-terminal simulation of all four installer profiles (including optional-stage skips and mandatory-stage failure handling). The full disposable-VM integration matrix is documented in [the installer validation plan](docs/installer-validation-plan.md); CI does not install eGamesAPI or modify a live VPS.

## Project layout

- `config/` — local configuration examples and tracked defaults.
- `modules/` — installer stages.
- `lib/` — shared shell/Python logic.
- `checks/` — read-only audits and guarded eGamesAPI adapters.
- `tests/` — regression tests.
- `docs/` — topology and implementation notes.
- `.github/workflows/` — CI workflows.

This project is not affiliated with eGamesAPI, Remnawave, MTProxyL, Telemt or Cloudflare.
