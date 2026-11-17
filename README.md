# server-deployment

Safety-first deployment orchestrator for a single-server stack built around **eGamesAPI Remnawave Reverse Proxy**, Remnawave/Xray, MTProxyL/Telemt and HAProxy.

> **Status: early development / integration scaffold.** The deployment orchestration and MTProxyL HAProxy integration are under active development. External installers and Remnawave Config Profile mutation remain explicit integration points until their exact upstream versions and API contracts are pinned and tested.

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

    Internet :80/:443
           |
           v
    HAProxy (public entry point after migration)
           |-- WEB SNI        -> MTProxyL WEB TLS backend
           |-- Remnawave SNI  -> 127.0.0.1:1443 (Xray)
           `-- default        -> MTProxyL MTProto backend

    Xray fallback -> eGamesAPI Nginx Unix socket

The HAProxy stage is an adapter for the MTProxyL-managed configuration, not a standalone HAProxy installer. Set `REMNAWAVE_SNI_DOMAINS` in `config/domains.env` as a space-separated list (for example, `gateway.example.com sync.example.com storage.example.com`) and set `WEB_DOMAIN` separately. The stage requires MTProxyL to use `FRONT_SERVER='haproxy'` with `NGINX_CUSTOM_ENABLED='true'`. Discovery reads the active HAProxy config as the source of truth for public binds and backend endpoints, then checks backend listener readiness. The recommended option preserves the discovered layout. Manual mode accepts target ports for Xray, MTProto, WEB TLS/HTTP and Selfmask. Public HTTP/HTTPS entry ports are always retained from discovery to avoid accidentally breaking ACME or external routing. Hosts are retained from discovery; the WEB TLS local bind and its upstream endpoint are updated together. Backend readiness checks match the requested bind address and configurable process-name hints (`XRAY_LISTENER_PROCESS_HINT`, `MTPROTO_LISTENER_PROCESS_HINT`, `WEB_HTTP_LISTENER_PROCESS_HINT` in `config/services.env`), not merely any listener on the same numeric port. If a backend is not listening on the selected port yet, or a new public bind is occupied, the stage saves a root-only pending plan and makes no active-config change. The operator can configure the relevant services, rerun the Xray adapter stage to see the pending Xray target, then rerun HAProxy setup and choose manual mode to reuse/edit the saved plan. Once listeners are ready, the stage patches only the managed bind/server directives and Remnawave SNI ACL, validates the candidate with the configured MTProxyL HAProxy binary, creates a timestamped backup and reloads the service. If validation fails, the active file is left untouched; if reload fails, the previous file is restored.

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
