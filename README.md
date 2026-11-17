# server-deployment

Safety-first deployment orchestrator for a single-server stack built around **eGamesAPI Remnawave Reverse Proxy**, Remnawave/Xray, MTProxyL/Telemt and HAProxy.

> **Status: early development / integration scaffold.** The orchestration, configuration model, preflight checks, backup framework and validation commands are provided. External installers and Remnawave Config Profile mutation remain explicit integration points until their exact upstream versions and API contracts are pinned and tested.

## Deployment order

1. **Preflight** — verify OS, domains, privileges and ports.
2. **System** — install base packages and create state directories.
3. **eGamesAPI + Remnawave** — use the official eGamesAPI installer; it installs/configures Remnawave as part of its flow. Do not install a second Remnawave stack.
4. **Network adapter** — prepare and verify the intended Xray inbound change to 127.0.0.1:1443 and preserve the eGamesAPI Nginx Unix-socket fallback. API mutation is disabled until a tested API contract is available.
5. **MTProxyL** — install the selected, reviewed MTProxyL version and configure internal listeners.
6. **HAProxy** — render and validate a starter config; merge/apply only after review.
7. **Validation** — check DNS, ports and services.
8. **Backup** — create/list/restore project-managed backups.

**Why this order?** eGamesAPI is first because its installation flow includes Remnawave and expects public HTTPS ports to be available. After installation, Xray can be moved to loopback port 1443. MTProxyL/HAProxy can then own public 80/443.

## Quick start

    git clone https://github.com/brusvv/server-deployment.git
    cd server-deployment
    cp config/domains.env.example config/domains.env
    nano config/domains.env
    chmod +x install.sh modules/*.sh checks/*.sh tests/*.sh
    sudo ./install.sh --check

Default mode is check-only. Execute one stage explicitly:

    sudo ./install.sh --run --stage preflight
    sudo ./install.sh --run --stage system

## Layout

- config/ — domains, ports and service paths.
- lib/ — shared Bash helpers and config loading.
- modules/ — ordered deployment stages.
- checks/ — DNS, port and service diagnostics.
- templates/ — generated configuration templates.
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

The HAProxy template is a starting point, not a drop-in replacement for an existing MTProxyL-managed config. Review and merge it with the actual installed configuration before activation.

## Safety

- No automatic firewall changes or service stops.
- No secrets belong in tracked files.
- No unpinned remote script is downloaded and executed.
- Existing files are backed up before replacement by project-managed operations.
- No Remnawave Config Profile is modified until its exact API schema, profile and inbound identifiers are verified.
- Check-only is the default.

## Development

    ./tests/shellcheck.sh

This project is not affiliated with eGamesAPI, Remnawave or MTProxyL.
