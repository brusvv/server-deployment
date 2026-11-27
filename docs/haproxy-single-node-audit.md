# HAProxy single-Node audit — 2026-11-26

## Purpose

Record observations from the disposable single-Node test VM that are useful when adjusting the installer. This is an environment snapshot, not a universal deployment specification. Re-run the commands before applying any changes; do not treat old listener/process state as current.

Scope for this test: one Remnawave Node, no cascade and no Shadowsocks bridge. The goal is to complete server-side routing and HAProxy configuration before client end-to-end testing.

## Confirmed VM observations

Collected from the operator's read-only command output on 2026-11-26:

| Item | Observed state |
|---|---|
| OS host name | `ubuntu` |
| HAProxy system package/binary | Not installed; `haproxy` command not found |
| HAProxy systemd unit | Not found; inactive / not installed |
| Xray process | `rw-core`, executable `/usr/local/bin/xray` |
| Xray public listener | `*:443/tcp` |
| Xray loopback listener | No listener found on `127.0.0.1:1443` |
| Other historical candidate ports | No listener found on `15443` or `15444` |
| Node Docker network | `host` |
| Node published Docker ports | None (host networking) |
| Nginx Docker network | `host` |
| Nginx shared socket | `/dev/shm/nginx.sock` exists and is listening |
| Remnawave Panel/API | Docker-published on loopback ports `3000` and `3001` |
| Subscription page | Docker-published on loopback port `3010` |
| PostgreSQL | Docker-published on loopback port `6767` |
| Host service list | No running host systemd unit matching HAProxy/MTProxy/Telemt/eGames |

The Xray process command line obtains its configuration from the Remnawave internal config endpoint. The token was deliberately redacted from the captured output and must not be copied into documentation, logs or issue reports.

## Repository implementation facts

The current adapter implementation is intentionally coupled to an already-installed MTProxyL-managed HAProxy service:

- `modules/03-network-adapter.sh` describes the intended Remnawave Xray listener as `127.0.0.1:1443` (or the configured `XRAY_LOOPBACK_HOST:XRAY_LOOPBACK_PORT`). It does not mutate the Remnawave Config Profile.
- `modules/05-haproxy.sh` does not install HAProxy or create a complete standalone HAProxy deployment. It patches an existing active MTProxyL custom configuration.
- The stage requires the configured HAProxy config, executable, MTProxyL settings and systemd unit to exist and match one another.
- It requires `FRONT_SERVER='haproxy'` and `NGINX_CUSTOM_ENABLED='true'` in the MTProxyL settings.
- The configured HAProxy service must be active for a live update/reload.
- The stage discovers the existing frontend/backend layout, validates backend listeners, builds a candidate with `lib/haproxy_config.py`, validates it with the configured HAProxy binary, backs up the active config, then reloads with rollback on failure.
- When prerequisites or backend listeners are missing, the stage must skip/fail safely; it must not replace or reload the active config.
- `config/services.env` points to the MTProxyL-managed paths `/opt/mtproxyl/haproxy-custom.cfg`, `/opt/mtproxyl-haproxy/sbin/haproxy` and `mtproxyl-haproxy.service`. These are not the Ubuntu package defaults.
- `config/ports.env` defaults include Xray loopback `127.0.0.1:1443`, MTProto backend `127.0.0.1:15443`, WEB TLS `127.0.0.1:15444`, WEB HTTP `127.0.0.1:15080`, and Selfmask-related ports. The historical MTProto backend on 15443 is not a Shadowsocks bridge.

## Consequences for this VM

1. Do not install the Ubuntu `haproxy` package as an assumed fix. That would not satisfy the configured MTProxyL binary/service paths or the adapter's prerequisites.
2. Do not switch the Remnawave inbound from public `:443` to loopback `:1443` yet. The current Xray process owns public `:443`; changing the profile before a working HAProxy frontend is ready could interrupt client entry.
3. The intended adapter hand-off is not yet complete: the actual Xray listener is not on the expected loopback endpoint.
4. The existence of `/dev/shm/nginx.sock` confirms the Nginx socket is present, but does not by itself prove the HAProxy fallback route or its protocol/health-check behavior.
5. Host networking on both `remnanode` and `remnawave-nginx` means their listeners share the host network namespace. Do not expect Docker port mappings for those containers.
6. The current VM evidence does not yet establish whether MTProxyL is absent from disk or merely not active. Inspect the configured directories, settings and systemd unit before deciding whether to install it or choose a standalone HAProxy design.

## Next read-only checks

Run these before changing ports or installing anything:

```bash
for d in /opt/mtproxyl /opt/mtproxyl-haproxy /opt/remnawave /var/lib/server-deployment; do
  if [ -d "$d" ]; then
    echo "FOUND: $d"
    sudo find "$d" -maxdepth 2 -type f \\
      \( -name 'settings.conf' -o -name 'haproxy-custom.cfg' \\
         -o -name '*haproxy*.service' -o -name 'haproxy' \) \\
      -printf '%p\\n' 2>/dev/null
  else
    echo "MISSING: $d"
  fi
done

systemctl list-unit-files --no-pager |
  grep -Ei 'haproxy|mtproxy|telemt|edgeguard' || true

ps -eo pid,comm,args |
  grep -Ei '[h]aproxy|[t]elemt|[e]dgeguard|[m]tproxy' || true

cd /opt/server-deployment
sudo ./install.sh --check --stage adapter
```

The operator ran the command with `--stage network-adapter` and received `Unknown stage: network-adapter`. This is a CLI naming mismatch, not evidence that the adapter module is broken: the stage identifier exposed by the installer is `adapter` (the implementation file is named `03-network-adapter.sh`). Use `--stage adapter` in subsequent checks.

## Additional VM findings (2026-11-26 23:35 UTC)

The follow-up read-only checks returned:

- `/opt/mtproxyl` — missing.
- `/opt/mtproxyl-haproxy` — missing.
- `/opt/remnawave` and `/var/lib/server-deployment` — present.
- No matching installed systemd unit files for HAProxy, MTProxyL, Telemt or EdgeGuard.
- No matching running processes for HAProxy, Telemt, EdgeGuard or MTProxyL.
- The attempted stage check using the non-existent name `network-adapter` returned `[ERROR] Unknown stage: network-adapter`.

This confirms that the expected MTProxyL-managed HAProxy installation is not present in its configured directories and is not registered under the searched unit/process names. It does not prove that no related files exist elsewhere on the host.

### Installer correction candidate

The operator-facing CLI documentation and examples should consistently call this stage `adapter`, while the script filename may remain `03-network-adapter.sh`. Add a regression test that invokes `--check --stage adapter` and verifies the guided, non-mutating output. Consider improving the unknown-stage error to list valid stage identifiers so filename-based guesses such as `network-adapter` are easier to diagnose.

Review the output before deciding between:

- **MTProxyL-integrated mode:** install/review the operator-supplied MTProxyL component, ensure its custom HAProxy config and service are active, then use the existing guarded HAProxy adapter.
- **Standalone HAProxy mode:** a separate implementation would be required. Do not silently retrofit the MTProxyL adapter or assume that the standard Ubuntu package is compatible.

## Security and evidence handling

- Never record API tokens, internal Remnawave URLs containing tokens, WARP private keys, passwords, certificates or full process environments.
- Redact public IPs and hostnames before sharing externally.
- This snapshot is from a disposable test VM and is not evidence that production hosts have the same state.
- No installation, service reload, Remnawave profile mutation or firewall change was performed during this audit.


## Additional operator observations (2026-11-26 23:37 UTC)

### Adapter check

The operator reran the check with both stage identifiers:

- `--stage network-adapter` returned `Unknown stage: network-adapter`.
- `--stage adapter` was recognized and printed the expected target `127.0.0.1:1443` and fallback socket `/dev/shm/nginx.sock`.
- The check explicitly stated that no Remnawave profile was changed and that automatic mutation remains disabled pending a pinned/tested OpenAPI schema, selected profile, inbound ID and update payload.

This is a successful non-mutating stage check, not evidence that the Xray listener has moved to loopback or that HAProxy is installed/running. The previous live-listener observation remains authoritative until a fresh socket check proves otherwise.

### eGames website template conflict — operator report

The operator reports that after installing eGames, the website displays the eGames-provided template instead of the project's games template.

The operator clarified the intended design: installing the eGames-provided template may be a required/base installation step, but a project-owned post-install function should then transform/customize that installed template into the project's games website. Therefore, do not treat this as a simple requirement to skip eGames template installation or merely preserve existing files. The expected flow is an ordered post-install customization step.

The exact mechanism and current hook point have not yet been established. Treat the following as the implementation target to verify against the repository and upstream eGames layout:

1. Trace the eGames installation path and identify the template source, destination/document root, and the point at which eGames finishes writing its default template.
2. Locate any existing project function, patcher, asset overlay, or post-install hook intended to customize the eGames template into the games website.
3. Ensure the customization runs after eGames has completed template installation and before the installer reports success.
4. Make the transformation repeatable (idempotent), scoped to known files/assets, and safe against upstream template changes. Avoid blind recursive copying or destructive replacement.
5. Add a post-install verification that checks the expected games-page assets/content and confirms the active document root serves the customized template, not the untouched eGames default.
6. Test both a fresh install and a rerun/update path; verify failure is visible and does not leave the installer claiming success with the wrong site.

No corrective code change has been made yet; first trace the actual installer and identify the intended transformation function/hook.


## Proposed product architecture: DLC / add-ons

The operator prefers a dedicated **DLC (add-ons)** section over a single eGames post-install customization hook. The reason is that more project-specific additions are expected later, and some may eventually be automated.

### Intended lifecycle

1. Install the upstream eGamesAPI component and its stock website template as part of the base installation.
2. Expose a separate DLC/add-ons menu after the base component is installed.
3. Provide a project-owned website-template DLC that transforms/customizes the stock eGames template into the project's games website.
4. Allow future DLCs to add other project-specific website features or integrations without coupling them to the base eGames installer.

The website-template DLC should be repeatable, detect whether eGames is installed, validate the expected upstream template/version before modifying it, back up files it changes, and verify the resulting games website. It should not silently run against an unknown document root or overwrite unrelated operator content.

### Design considerations (proposal, not implemented)

- Keep base eGames installation and project DLC lifecycle separate.
- Each DLC should have clear metadata: identifier, display name, description, prerequisites, install/update/remove/check actions, and compatibility requirements.
- Provide a shared DLC dispatcher/menu rather than adding one-off menu branches for every future add-on.
- Make install/update/check/remove operations explicit and idempotent where possible.
- Track installed DLC state and version so the installer can report status and safely update/remove additions.
- Separate upstream-owned files from project-owned overlays/patches; prefer managed overlays or narrowly scoped transformations over uncontrolled recursive replacement.
- Add a non-mutating check/dry-run path and backups/rollback for file-changing actions.
- Keep automatic post-install application optional until dependency ordering and failure handling are defined. The initial user-facing flow can be: install eGames base, then explicitly install the project games-template DLC. Later, automate this hand-off after the base install succeeds.

This is an architectural direction agreed in discussion, not a claim that a DLC framework already exists in the repository. Before implementation, inspect the current menu, module registry, eGames installer and website file layout, then fit the DLC dispatcher into the existing project conventions.

## Installer path review — 2026-11-27

Reviewed the interactive profile dispatcher, profile definitions, stage runner and relevant stage scripts on `fix/warp-local-panel-api`.

### Profile/menu findings

- The interactive menu currently exposes three profiles: standard Remnawave, Remnawave with additional components, and cascade.
- There is no separate DLC/add-ons menu or dispatcher yet.
- The standard profile runs `preflight → backup → system → remnawave → validate`.
- The extended profile runs `preflight → backup → system → remnawave → adapter → mtproxyl → haproxy → validate → warp-masque`; MTProxyL, HAProxy and WARP/MASQUE are marked optional.
- The one-host test scope should use the standard profile or the extended profile with its optional network integrations deliberately excluded until the HAProxy architecture is decided. Cascade profiles are out of scope for this audit.

### eGames and website-template findings

- `modules/02-remnawave.sh` fetches a pinned eGamesAPI installer commit, verifies the commit and script version, then launches the upstream interactive installer.
- It asks the operator to select eGames menu item 1, then item 1 (Panel + Node on one server).
- After eGames completes, this module runs `checks/remnawave-container-audit.sh` and then applies `checks/remnawave-nginx-hardening.sh --apply`.
- There is no project-owned games-template customization call in this stage.
- The repository contains two website HTML assets under `web/`: `black-universe.html` and `classic_arcades.html`. No DLC framework or template installation/update/remove command is currently present in the reviewed menu or stage runner.
- Therefore the reported stock eGames template is consistent with the current code path: eGames installs its own site, and the project does not subsequently invoke a function to deploy either of its own HTML templates. This is a repository-code finding; the exact live document root and which HTML asset should be selected still need confirmation from the installed host.

### Important safety finding: `--check` is not globally read-only

The CLI exports `SD_MODE=check`, but several stages do not gate mutations on that mode:

- `modules/01-system.sh` still prompts and runs `apt-get update`, `apt-get install`, and creates directories.
- `modules/02-remnawave.sh` launches the eGamesAPI installer and later applies Nginx hardening.
- `modules/04-mtproxyl.sh` can run a local installer if `MTPROXYL_INSTALLER_LOCAL` is set and the operator confirms.
- `modules/07-backup.sh` creates a backup by default; it checks `SD_DRY_RUN`, not `SD_MODE`.

Thus `--check` must not be described as a universal dry-run, and operators must not use it indiscriminately across all stages. In the current implementation, the reviewed `adapter`, `haproxy` check branch (when prerequisites are absent/present), `validate`, and `preflight` paths are intended as checks, but each should still be reviewed before execution. The installer should be corrected so check mode is guaranteed non-mutating by construction, ideally with stage-level tests that fail if package installs, writes, service reloads, profile updates, or backup creation occur.

### Next safe test commands for this VM

After reviewing these commands, the operator can run only the following check-oriented stages (do not substitute `system`, `remnawave`, `mtproxyl`, or `backup` under `--check`):

```bash
cd /opt/server-deployment
sudo ./install.sh --check --stage preflight
sudo ./install.sh --check --stage haproxy
sudo ./install.sh --check --stage validate
```

These results should be collected before any port/profile/service changes. The eGames site-template DLC itself is not implemented yet.

## VM check results — 2026-11-26 23:55 UTC

Operator ran `sudo ./install.sh --check --stage preflight`, `haproxy`, and `validate` on the disposable Ubuntu VM.

Observed results:
- All configured domains resolved successfully.
- TCP/80 was free.
- TCP/443 was occupied by `rw-core` (Xray), consistent with the earlier listener snapshot.
- Shadowsocks bridge checks were skipped because the bridge is disabled.
- HAProxy check skipped because MTProxyL active HAProxy config, binary, or settings were not found.
- Validation warned that `remnanode` and `mtproxyl-haproxy.service` were not found as systemd units.

Interpretation:
- The `remnanode not found` warning is a diagnostic false negative for this deployment: Node is a Docker container, not necessarily a systemd unit. `checks/services.sh` currently checks only `systemctl list-unit-files`; it should inspect Docker containers when the configured service hint refers to a container.
- The HAProxy check result does not establish that MTProxyL is absent from disk; it only establishes that the configured active HAProxy integration prerequisites were not found by this stage.
- The current public 443 listener must not be moved until a replacement frontend is configured, validated, and ready to bind.
- The duplicate domain-resolution lines arise because preflight/validation invoke domain checks through more than one path; consider de-duplicating output when improving diagnostics.

Next: inspect MTProxyL paths, unit files and processes read-only; do not install HAProxy or change Xray's 443 listener yet.

## Final MTProxyL / HAProxy host inspection — 2026-11-27

The operator completed the follow-up read-only inspection on the disposable Ubuntu VM.

### Docker containers

The complete `docker ps -a` output contained only the Remnawave stack:

- `remnanode` — `remnawave/node:latest`, running.
- `remnawave-subscription-page` — healthy; published on loopback port 3010.
- `remnawave` — backend image; healthy; published on loopback ports 3000–3001.
- `remnawave-db` — PostgreSQL; healthy; published on loopback port 6767.
- `remnawave-redis` — Valkey; running.
- `remnawave-nginx` — Nginx; running.

No MTProxyL, HAProxy, Telemt or EdgeGuard container appeared in this listing.

### Binary and filesystem inspection

- `command -v haproxy` returned no path.
- `whereis haproxy` returned only the command label, with no binary or directory.
- The bounded search under `/opt` and `/usr/local` found only this repository's HAProxy-related source/test files (`lib/haproxy_config.py`, its Python cache, `tests/mtproxyl-installer-guard.sh`, `tests/fixtures/haproxy.cfg`, `modules/04-mtproxyl.sh`, and `modules/05-haproxy.sh`). It did not find an installed HAProxy binary or MTProxyL installation directory.
- Together with the prior empty systemd-unit and process searches and the missing configured MTProxyL directories, this establishes that the expected MTProxyL-managed HAProxy integration is not installed/running in the inspected locations on this VM.

This is a bounded host inspection, not proof that no similarly named file exists anywhere on the filesystem.

### Updated conclusion and installer implications

1. The VM currently runs the Remnawave Docker stack only; no MTProxyL/HAProxy component was found in the inspected Docker, systemd, process, binary or configured-directory locations.
2. The current architecture cannot proceed through the existing MTProxyL-coupled HAProxy stage without first installing and configuring MTProxyL, or implementing a distinct standalone HAProxy deployment path.
3. Do not install the stock Ubuntu HAProxy package as a drop-in substitute: the current stage expects MTProxyL-specific config, binary and service paths.
4. Do not move Xray off public TCP/443 until a replacement frontend has been installed, configured, validated and is ready to bind that port.
5. The service validator should be updated to recognize Docker-managed Remnawave Node containers (or distinguish a Docker service hint from a systemd unit). The current `checks/services.sh` only queries systemd unit files, so its `remnanode not found` warning is misleading for this deployment.
6. For the current one-Node/no-cascade test, decide explicitly whether MTProxyL is a required dependency or whether standalone HAProxy is a supported architecture. Keep the two modes separate rather than silently treating the existing MTProxyL adapter as a generic HAProxy installer.

No packages were installed, containers changed, services restarted, ports moved, or Remnawave profiles modified during these inspections.

## Architecture comparison: MTProxyL-managed HAProxy vs standalone HAProxy — 2026-11-27

This comparison combines the current repository implementation, the operator's disposable-VM observations, and a review of the current upstream MTProxyL README/source. It is a design assessment; neither option has been installed or live-tested on this VM.

### Option A — MTProxyL owns HAProxy

There are two distinct MTProxyL arrangements which must not be conflated:

1. **MTProxyL-managed HAProxy frontend.** Current MTProxyL upstream can install and manage its own HAProxy 3.2 build (the current source declares its own prefix, service and custom config paths). It uses HAProxy for MTProxyL's WEB/Selfmask and, in shared mode, SNI-based distribution between its WEB listener and the Telemt MTProto listener.
2. **External HAProxy.** MTProxyL can instead generate a fragment for an already-existing HAProxy. In that mode MTProxyL does not install, start, own or manage the external HAProxy or its certificate. Its WEB listener must be protected by firewall and trusted-proxy settings.

The repository's current modules/05-haproxy.sh is not a generic integration with either mode. It expects the MTProxyL-managed config, binary, settings and active systemd service at the configured paths; it edits a known MTProxyL config layout. It currently checks FRONT_SERVER='haproxy' and NGINX_CUSTOM_ENABLED='true'. Its Python patcher expects particular frontend/backend section names and one-bind/one-server shapes. Compatibility with the current upstream MTProxyL-generated HAProxy config must be demonstrated against a pinned upstream release before reusing this patcher.

**What MTProxyL adds beyond HAProxy:** Telemt MTProto proxy management (users/secrets/links), engine installation/update/rollback, traffic/connection monitoring, backups, optional panel/bot, Selfmask and its website templates, WEB Proxy, and network/security features such as NFT SYN limiting, geoblocking and upstream routing. These are useful only if the operator actually wants those services/features on this VPS.

**Benefits**
- Reuses the existing repository's MTProxyL-oriented stage/config model, so less new HAProxy lifecycle code may be needed.
- A single upstream manager owns its Telemt engine and its own frontend configuration.
- If Telegram MTProto, Selfmask or MTProxyL WEB is a real requirement, these are integrated features rather than functionality the project must recreate.
- MTProxyL's managed HAProxy build includes its own TLS/OpenSSL and static-site components; the upstream project documents this as its supported frontend choice.

**Costs and risks**
- Adds a second major service stack (MTProxyL/Telemt, settings/state, possible static-site service and optional panel/bot) even if only HAProxy routing is required.
- Adds another upstream release/update lifecycle and configuration owner. The project must avoid two tools independently rewriting the same HAProxy file.
- MTProxyL's shared frontend is designed around its own Telemt/WEB/Selfmask traffic. The required Remnawave SNI route and eGames/Nginx fallback must be integrated without breaking its default backend, PROXY protocol expectations, TLS handling or WEB routing.
- The current repository's MTProxyL installer hand-off is an operator-supplied local script, not a pinned, fully automated integration. The current stage does not install MTProxyL by itself.
- MTProxyL's latest upstream capabilities and generated config layout have evolved; the current repository adapter's assumptions need a compatibility audit and regression fixtures.

### Option B — standalone HAProxy managed by this project

The project installs/pins HAProxy itself, owns a complete project config and systemd unit, and routes only the services required by this deployment. MTProxyL is not installed.

A minimal single-Node target would likely have:
- Public TCP/443 owned by HAProxy.
- Remnawave Xray moved to a loopback-only endpoint such as 127.0.0.1:1443.
- SNI rules that send the configured Remnawave names to Xray using TCP/TLS passthrough.
- A deliberately defined fallback for other SNI/no-SNI traffic, likely to the existing eGames Nginx endpoint/socket, after confirming the actual Nginx protocol and fallback behavior.
- Public TCP/80 handling only if required for HTTP redirects/ACME; otherwise leave it with the existing owner or keep it closed.
- No MTProto backend, Telemt listener, MTProxyL WEB listener, Selfmask or MTProxyL static backend unless separately requested.

**Benefits**
- Smallest runtime architecture when the requirement is only Xray SNI passthrough plus a web fallback.
- One owner for the routing config: this repository. No dependency on MTProxyL settings, generated file layout or installer.
- Simpler lifecycle and diagnostics: one pinned HAProxy binary/package, one systemd service, one managed config, explicit backend health checks and rollback.
- Can be designed exactly around the actual Remnawave + eGames Nginx topology instead of adapting a Telegram proxy manager's topology.
- Avoids installing an unused Telemt engine, its state and optional management components.

**Costs and risks**
- More initial implementation work: the repository currently has a conservative MTProxyL config patcher, not a complete standalone HAProxy installer/config generator/service manager.
- The project must own HAProxy version pinning, binary/package provenance, systemd unit hardening, config validation, backups/rollback, reload checks, upgrade strategy and uninstall behavior.
- TLS passthrough/SNI inspection and fallback behavior must be designed and tested explicitly. HAProxy should not terminate TLS for the Remnawave Xray route. Any PROXY protocol header must only be enabled if the receiving backend is configured to accept it.
- eGames Nginx fallback must be validated at the protocol level. The existence of /dev/shm/nginx.sock alone does not establish whether it is a stream socket, what protocol it accepts, or how it handles TLS and SNI.
- If the operator later wants Telegram MTProto, Selfmask or MTProxyL WEB, those become a separate optional component and require an explicit integration design.

### Comparison for the current one-Node test

| Criterion | MTProxyL-managed HAProxy | Standalone HAProxy |
|---|---|---|
| Initial setup on this VM | More components to install and configure | Fewer runtime components |
| Reuse of current repository code | Higher, but adapter compatibility with current upstream config is unverified | Lower; requires a new standalone implementation |
| Runtime footprint | Higher: MTProxyL + Telemt and related optional services | Lower: HAProxy only |
| Ownership of routing config | Shared boundary: MTProxyL generates/owns base config; project patches it | Single owner: this project |
| Telegram MTProto | Included | Not included |
| Selfmask / MTProxyL WEB | Included as MTProxyL features | Must be implemented separately or omitted |
| Xray + eGames Nginx routing | Requires careful extension of MTProxyL's existing SNI routes | Can be purpose-built for these backends |
| Long-term maintenance | Depends on MTProxyL config compatibility and upstream changes | Depends on this project's HAProxy maintenance |
| Best fit | VPS is also intended to run Telegram MTProto/MTProxyL features | VPS only needs Remnawave ingress and web fallback |

### Provisional recommendation

For the scope currently confirmed — one Remnawave Node, no cascade/bridge, existing eGames Nginx, and a need to route public 443 between Xray and a web fallback — **standalone HAProxy is likely the simpler final architecture and has the smaller runtime footprint**, provided Telegram MTProto, MTProxyL Selfmask and MTProxyL WEB are not requirements.

This does not mean it is less work today: the repository must first gain a complete, tested standalone HAProxy lifecycle. The existing MTProxyL adapter cannot simply be pointed at /etc/haproxy/haproxy.cfg.

Choose MTProxyL-managed HAProxy if the same VPS is also intended to run MTProto/Telemt or if MTProxyL's Selfmask/WEB features are specifically wanted. In that case, prefer MTProxyL's own supported frontend manager and integrate the Remnawave route through a version-pinned, tested extension point; do not assume the current patcher is compatible with every current upstream config.

### Decisions and validation required before implementation

1. Confirm whether Telegram MTProto/Telemt is a requirement on this VPS. If not, do not add MTProxyL solely to obtain HAProxy.
2. Inspect the actual eGames Nginx socket type and the Nginx configuration's fallback behavior, without exposing certificate/key contents.
3. Confirm the desired behavior for unknown SNI, absent SNI, and HTTP on port 80. Do not route arbitrary traffic to Xray by default without an explicit policy.
4. Determine whether the Remnawave inbound uses TLS/REALITY and verify the exact SNI visible to HAProxy; keep the Xray path as TCP passthrough.
5. Build a disposable test config and validate HAProxy's config syntax, listener ownership, SNI matching, Xray handshake, Nginx fallback, and rollback before moving the live Xray listener.
6. If choosing MTProxyL, pin an exact upstream release and add a fixture from its generated HAProxy config; test that the project's SNI rule survives MTProxyL regeneration/update. If choosing standalone, add a complete managed config template and service lifecycle instead of reusing the MTProxyL patcher.

No packages, services, ports, Remnawave profiles or VM configuration were changed as part of this comparison.
