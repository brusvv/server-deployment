# server-deployment

Safety-first deployment orchestrator for a single-server stack built around **eGamesAPI Remnawave Reverse Proxy**, Remnawave/Xray, MTProxyL/Telemt and HAProxy.

> **Status: early development / integration scaffold.** The deployment orchestration and MTProxyL HAProxy integration are under active development. External installers and Remnawave Config Profile mutation remain explicit integration points until their exact upstream versions and API contracts are pinned and tested.

## Feature branch: HTTP redirects and SelfSteal website

This branch extends the MTProxyL-managed HAProxy integration. The opt-in HTTP → HTTPS redirect and dedicated ACME HTTP-01 backend are implemented and covered by regression tests. The SelfSteal website choices described below remain a planned feature and are not installed or managed by the current code.

### HTTP → HTTPS redirects

- The default remains **Strict**. Leave `HTTP_REDIRECT_DOMAINS` empty to preserve the current HTTP frontend behavior.
- To opt in, set `HTTP_REDIRECT_DOMAINS` in `config/domains.env` to a space-separated allowlist of hostnames that should receive HTTP → HTTPS redirects. The list is explicit; the script does not assume that every configured SNI hostname should be redirected.
- Listed hosts receive a same-host `301` redirect to HTTPS. Unknown Host values receive `404`.
- ACME HTTP-01 requests under `/.well-known/acme-challenge/` bypass the redirect and are routed to the dedicated ACME webroot backend.
- The ACME backend defaults to `127.0.0.1:18080` (`ACME_WEBROOT_HOST` / `ACME_WEBROOT_PORT`). The service must be listening before redirects are enabled; the HAProxy stage checks it before applying the config.
- Example loopback-only webroot container:

      install -d -m 0755 /var/www/acme/.well-known/acme-challenge
      docker run -d --name acme-webroot --restart unless-stopped \
        -p 127.0.0.1:18080:80 \
        -v /var/www/acme:/usr/share/nginx/html:ro nginx:alpine

- Certbot can use `--webroot -w /var/www/acme`. Existing certificates and renewal configs are not rewritten by the HAProxy stage.

### SelfSteal website

Website content is configured independently from HTTP redirect behavior. The planned choices are:

1. **Keep current website** — do not replace existing content.
2. **Built-in website** — install the bundled Polish-language static HTML website.
3. **Custom website directory** — use an operator-provided website directory.

The existing REALITY → Nginx Unix-socket fallback path is to be preserved. Website files must be managed separately from generated HAProxy configuration, and upgrades must not silently overwrite an operator's custom or previously installed website.

### Compatibility and safety

- HTTP redirects are opt-in through `HTTP_REDIRECT_DOMAINS`; an empty value preserves the strict behavior.
- Existing HAProxy SNI routing, backend discovery, public binds and ACME handling must remain intact.
- The MTProxyL WEB backend is normalized to `mtproxyl_web_backend` to avoid a frontend/backend name collision on newer HAProxy releases.
- The ACME webroot backend is discovered from the active config when present; otherwise the configured loopback endpoint is used.
- Xray listener validation is deferred by default until Remnawave Node is installed. Set `XRAY_LISTENER_REQUIRED=1` when the listener must be present before applying HAProxy changes.
- Generated configuration is validated before activation; the active configuration is backed up before replacement.
- The implementation must support non-interactive/check-only execution without unexpectedly prompting or changing the current defaults.

## Deployment order

1. **Preflight** — verify OS, domains, privileges and ports.
2. **System** — install base packages and create state directories.
3. **eGamesAPI + Remnawave** — use the official eGamesAPI installer; it installs/configures Remnawave as part of its flow. Do not install a second Remnawave stack.
4. **Network adapter** — prepare and verify the intended Xray inbound change to 127.0.0.1:1443 and preserve the eGamesAPI Nginx Unix-socket fallback. API mutation is disabled until a tested API contract is available.
5. **MTProxyL** — install the selected, reviewed MTProxyL version and configure internal listeners.
6. **HAProxy** — update only the Remnawave SNI ACL and Xray backend in MTProxyL's active custom config, validate it, back up the original and reload MTProxyL HAProxy.
7. **Validation** — check DNS, ports and services.
8. **Backup** — create/list/restore project-managed backups.

Official eGamesAPI upstream launch command (tracks `main`, not a pinned release; review changes before production use):

    bash <(curl -Ls https://raw.githubusercontent.com/eGamesAPI/remnawave-reverse-proxy/refs/heads/main/install_remnawave.sh)

At the time of this check, the script declares `SCRIPT_VERSION="3.8.4"`, while the latest published GitHub release is `v3.8.0`. The branch script is therefore newer than the latest formal release tag; do not treat those version labels as equivalent.

**Why this order?** eGamesAPI is first because its installation flow includes Remnawave and expects public HTTPS ports to be available. After installation, Xray can be moved to loopback port 1443. MTProxyL/HAProxy can then own public 80/443.

## Installing this feature branch

To install this branch rather than `main`:

    git clone --depth 1 --branch feature/http-redirect-selfsteal-website https://github.com/brusvv/server-deployment.git /opt/server-deployment
    cd /opt/server-deployment
    cp config/domains.env.example config/domains.env
    nano config/domains.env
    bash install.sh --check

If `config/domains.env` already exists from a previous installation, preserve it
when replacing the checkout and do not overwrite it with the example file. Set
real hostnames you control before running preflight; the example domains are
placeholders and will fail validation.

## Quick start

Remote bootstrap (clones the repository to `/opt/server-deployment` and starts the local installer):

    curl -fsSL https://raw.githubusercontent.com/brusvv/server-deployment/main/install.sh | bash -s -- --check

For an explicit execution run, pass `--run` (the default is check-only):

    curl -fsSL https://raw.githubusercontent.com/brusvv/server-deployment/main/install.sh | sudo bash -s -- --run

You can override the clone location with `SD_INSTALL_DIR=/path/to/server-deployment`.

For a manual checkout:

    git clone https://github.com/brusvv/server-deployment.git
    cd server-deployment
    cp config/domains.env.example config/domains.env
    nano config/domains.env
    chmod +x install.sh modules/*.sh checks/*.sh tests/*.sh
    sudo ./install.sh --check

Default mode is check-only. Execute one stage explicitly:

    sudo ./install.sh --run --stage preflight
    sudo ./install.sh --run --stage system
    sudo ./install.sh --check --stage haproxy
    sudo ./install.sh --run --stage haproxy

The HAProxy stage only applies when the MTProxyL custom HAProxy config is already active and its service is running. In run mode it offers an interactive port setup: option 1 adopts the layout discovered from the active config; option 2 lets the operator enter target ports; option 0 exits without changes. If a selected backend is not listening yet, or a requested public bind is occupied, the stage saves a root-only pending plan under the configured state directory and does not touch or reload the active config. Configure the underlying service(s), then rerun the stage and choose option 2 to reuse/edit the pending values.

## Layout

- config/ — Remnawave SNI domains, ports and service paths.
- lib/ — shared Bash helpers and config loading.
- modules/ — ordered deployment stages.
- checks/ — DNS, port and service diagnostics.
- tests/ — static shell checks.
- .github/workflows/ — CI lint and syntax checks.

## Requirements

- Debian or Ubuntu (other distributions are not yet supported).
- Root access for installation stages.
- DNS records for all configured domains.
- Public TCP 80/443 reachable from the Internet.
- Operator-reviewed, version-pinned upstream installers.

## Network model

    Internet :80
           |
           v
    HAProxy HTTP frontend
           |-- ACME path (when redirects are enabled) -> 127.0.0.1:18080
           |-- listed Host values                     -> same-host HTTPS 301
           `-- unknown Host values                    -> HTTP 404

    Internet :443
           |
           v
    HAProxy TCP/SNI frontend
           |-- WEB SNI        -> MTProxyL WEB TLS backend
           |-- Remnawave SNI  -> 127.0.0.1:1443 (Xray)
           `-- default        -> MTProxyL MTProto backend

    Xray fallback -> eGamesAPI Nginx Unix socket

**Current scope:** every hostname listed in `REMNAWAVE_SNI_DOMAINS` is sent to the Xray backend. This adapter does not yet create separate HTTPS routes for Remnawave Panel or Subscription Page. Do not assign those hostnames to web applications until a separate reverse-proxy route is implemented and tested.

The verified reference-server state, including listener ports, ACME validation, certificate state, resource limits and items still outstanding, is recorded in [docs/validated-server-baseline-2026-11-18.md](docs/validated-server-baseline-2026-11-18.md). The document contains no deployment-specific domain names, IPs or secrets.

The HAProxy stage is an adapter for the MTProxyL-managed configuration, not a standalone HAProxy installer. Set `REMNAWAVE_SNI_DOMAINS` in `config/domains.env` as a space-separated list and set `WEB_DOMAIN` separately. Set `HTTP_REDIRECT_DOMAINS` explicitly when same-host HTTP → HTTPS redirects are desired; leave it empty to keep the strict/default behavior. The stage requires MTProxyL to use `FRONT_SERVER='haproxy'` with `NGINX_CUSTOM_ENABLED='true'`.

Discovery reads the active HAProxy config as the source of truth for public binds and backend endpoints. It recognizes both the legacy `mtproxyl_web` backend and the normalized `mtproxyl_web_backend`, plus the optional `mtproxyl_acme` backend. When redirects are enabled, the ACME webroot listener must be reachable at `ACME_WEBROOT_HOST:ACME_WEBROOT_PORT` (defaults to `127.0.0.1:18080`). The WEB TLS local bind and its upstream endpoint are updated together; Selfmask and static backend endpoints are discovered independently.

The recommended option preserves the discovered port layout. Manual mode accepts target ports for Xray, MTProto, WEB TLS/HTTP, the Selfmask backend, the static backend and the Selfmask local bind. Public HTTP/HTTPS entry ports are always retained from discovery. Backend readiness checks match the requested bind address and configurable process-name hints (`XRAY_LISTENER_PROCESS_HINT`, `MTPROTO_LISTENER_PROCESS_HINT`, `WEB_HTTP_LISTENER_PROCESS_HINT`, `SELFSTEAL_BACKEND_PROCESS_HINT` and `STATIC_LISTENER_PROCESS_HINT` in `config/services.env`). Xray readiness is deferred by default until Node installation; set `XRAY_LISTENER_REQUIRED=1` to make it mandatory. If a required backend is not listening or a requested new local HAProxy bind is occupied, the stage saves a root-only pending plan and makes no active-config change.

Once ready, the stage patches only the managed bind/server directives, Remnawave SNI ACL and the explicitly enabled HTTP/ACME rules, validates the candidate with the configured MTProxyL HAProxy binary, creates a timestamped backup and reloads the service. If validation fails, the active file is left untouched; if reload fails, the previous file is restored.

## Safety

- No automatic firewall changes or service stops.
- No secrets belong in tracked files.
- Third-party installers are not downloaded and executed automatically. The optional bootstrap command above fetches this project's own installer from `main`; review it before running and pin a commit for reproducible deployments.
- Existing files are backed up before replacement by project-managed operations.
- No Remnawave Config Profile is modified until its exact API schema, profile and inbound identifiers are verified.
- Check-only is the default.

## Development

    ./tests/shellcheck.sh

This project is not affiliated with eGamesAPI, Remnawave or MTProxyL.



## Branch scope and bootstrap behavior

The remote bootstrap command in this README tracks **`main`**. It does not select this cascade branch. To work with the cascade implementation, clone the branch explicitly:

    git clone --depth 1 --branch feature/remnawave-cascade-bridge https://github.com/brusvv/server-deployment.git
    cd server-deployment

The branch's `install.sh` bootstrap still defaults to cloning `main` when run from stdin; use the explicit branch checkout above, then run local commands from that checkout. The default deployment mode remains check-only.

## Remnawave cascade branch

This branch implements the main route for **VPS A (Russia — Entry) → VPS B (abroad — Panel + Exit)**.

- Client-facing VLESS + XHTTP terminates on A.
- When enabled, A → B uses a dedicated Shadowsocks bridge over TCP + UDP with `chacha20-ietf-poly1305`.
- The primary eGamesAPI Geo Bridge policy is `direct`: Russian IP/domain destinations leave directly through A; other traffic from the selected public profile is sent through the SS bridge and exits via B.
- The optional bridge is disabled by default (`SS_BRIDGE_ENABLED=0`). Its configurable `SS_BRIDGE_PORT` defaults to `9999/tcp+udp`; the selected port is not assumed free or listening.
- MTProto/Telemt is a separate service on B. Its Telegram traffic does not use the Shadowsocks bridge.

Before any deployment, run the read-only inventory on each VPS:

    sudo bash checks/cascade-audit.sh A
    sudo bash checks/cascade-audit.sh B

Run each command on the server identified by the argument. The audit does not read secrets, service environments, Docker environment variables or process command lines. Its output does include network addresses and firewall source addresses; review those before sharing.

### eGamesAPI local Exit compatibility

The stock eGamesAPI Server Routing module rejects an Exit host that matches the Panel's public IP, even when that host is the already registered local Node on VPS B. This branch includes a narrow, fail-closed compatibility patch. It allows the co-located Exit only when eGamesAPI can find the matching Node record, its profile, and a connected state; it does not disable the guard generally or permit a new/unknown local Node.

Locate the module on B, check the exact patch context, then apply it interactively:

    sudo find /opt/remnawave -type f -name server_routing.sh -print
    sudo python3 checks/egamesapi-local-exit-compat.py --check /path/to/server_routing.sh
    sudo python3 checks/egamesapi-local-exit-compat.py --apply /path/to/server_routing.sh

If the check says the module is not patchable, stop. Do not edit the guard manually; inspect the installed eGamesAPI version and Node address first. The patch creates a timestamped backup and validates Bash syntax before replacing the module.

Design notes:

- [Remnawave cascade bridge plan](docs/remnawave-cascade-bridge-plan.md)
- [MTProto networking model](docs/mtproto-networking.md)

VLESS Route is intentionally deferred. Do not configure the VLESS Route bridge during this phase.

### Optional Shadowsocks bridge settings

- The bridge is disabled by default: `SS_BRIDGE_ENABLED="0"` in `config/ports.env`.
- Run `./install.sh --configure-bridge` to choose enabled/disabled and, when enabled, the TCP+UDP port (default `9999`). An interactive full `./install.sh --run` asks the same questions before the stages begin. Changing the port while enabled updates only local config; the existing tunnel keeps its current settings. Run eGamesAPI Teardown before recreating it on the new port. Setting the bridge flag to `0` also does not stop an active tunnel; use Teardown first.
- Valid port range: `1–65535`, excluding `2222` (the eGamesAPI node-control default). Preflight checks the selected TCP and UDP port only when the bridge is enabled, and stops on a collision.
- Check-only and non-interactive runs never prompt; they use the saved settings.

The wizard updates only the local `config/ports.env` file and creates a timestamped backup. On VPS B, the eGamesAPI adapter reads those settings at runtime: it blocks Geo Bridge setup/attachment while disabled, forces the configured port, and pins the Geo Bridge routing mode to `direct`. Run `checks/egamesapi-bridge-adapters.sh --check` with the module and config paths before applying; `--apply` installs both guarded patches in order. Actual Remnawave inbound, service user/squad, Entry outbound/routing and source-restricted firewall operations still run through the eGamesAPI Server Routing workflow with explicit confirmation; see [the cascade plan](docs/remnawave-cascade-bridge-plan.md).
