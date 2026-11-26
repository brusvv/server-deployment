# Installer architecture

## Deployment choices

The interactive installer exposes three top-level choices:

1. **Обычная установка Remnawave** — eGamesAPI combined Panel + local Node mode (also includes its subscription page and reverse proxy), without additional repository components.
2. **Remnawave + дополнительные компоненты** — the extended single-host stack with network adapter, MTProxyL, HAProxy integration and optional WARP/MASQUE.
3. **Каскад Remnawave** — choose the role:
   - **VPS A / Entry** — Russian client-facing node.
   - **VPS B / Panel + Exit** — foreign Panel host and local Exit Node.

## Responsibilities

- install.sh is the stable CLI entry point, bootstrapper and non-interactive runner.
- installer/menu.sh handles selection and confirmation only; it never changes the host.
- installer/main.sh dispatches the selected profile stages.
- profiles define stage order and describe the role; they do not duplicate stage logic.
- modules contain executable installation stages.
- lib contains reusable primitives such as logging, config loading, backups and port discovery.
- checks contains read-only audits and guarded adapters.
- manage.sh remains a separate post-install management interface.

## Current profile stage maps

| Profile | Stage sequence |
|---|---|
| Standard Remnawave | preflight → backup → system → remnawave → validate |
| Extended Remnawave | preflight → backup → system → remnawave → adapter → mtproxyl → haproxy → validate → warp-masque |
| Cascade A / Entry | preflight → backup → system → validate |
| Cascade B / Panel + Exit | preflight → backup → system → remnawave → adapter → mtproxyl → haproxy → validate → warp-masque |

These stage maps describe the current repository capabilities, not a claim that every step fully provisions a production topology.

- eGamesAPI is fetched at a pinned commit (`93e6631aae5f7bff28eadfc45faab43150cc22c6`, v3.8.4), checked out and syntax-validated before its interactive installer is launched. MTProxyL remains an operator-supplied, reviewed local installer.
- The network adapter stage documents/checks the intended Xray listener arrangement; it does not mutate a Remnawave Config Profile.
- The HAProxy stage modifies an existing MTProxyL-managed custom config; it is not a standalone HAProxy installer.
- Cascade profiles do not create the live Shadowsocks inbound/outbound, service user/squad, routing rules or firewall rules. Those remain in the eGamesAPI Server Routing workflow.
- Entry does not install a Panel. Panel belongs on B.
- WARP/MASQUE is optional and independent of the A→B Shadowsocks bridge.

Do not expand a profile's responsibilities until its implementation, preconditions, rollback and tests exist.

## Interaction contract

When install.sh is invoked without arguments from an interactive terminal:

1. Show the main menu.
2. For cascade, show the A/B role selector.
3. Display the selected profile description and exact stage list.
4. Ask for confirmation:
   - **Yes** — start the selected profile.
   - **No** — cancel and return to the main menu.
   - **Exit** — terminate the installer and return to the shell.
5. Only after confirmation, run the declared stages in order.

Invalid input and EOF must never start a stage. A failed required stage stops the profile; later stages do not run. Optional stages return a dedicated skipped status, which the dispatcher records without describing the skipped component as installed. Only stages declared optional by the selected profile may be skipped.

Non-interactive no-argument invocation retains check-only behavior. Explicit CLI commands (--check, --run, --stage) remain available and do not open the menu.

## Safety invariants

- Menu rendering and selection are read-only.
- No package installation, service action, firewall mutation, Remnawave API call or filesystem mutation occurs before confirmation.
- Required system preparation and eGamesAPI installation fail closed when declined.
- The eGamesAPI Panel + Node combined mode is explicitly warned as not recommended for production by its upstream documentation.
- Existing optional-component confirmations remain in force; an opt-out is recorded as skipped.
- Check-only and dry-run behavior remain non-mutating.
- A role-specific profile must never execute the other role's stages.
- No profile may claim a complete cascade until cross-node provisioning, source-restricted firewall configuration and end-to-end routing validation are implemented and tested.
- Backups are not a substitute for provider snapshots or application-consistent backups.

## Bootstrap ref selection

Remote bootstrap uses SD_GIT_REF (default: main) to select the branch to clone. For the cascade feature branch, set SD_GIT_REF=feature/remnawave-cascade-bridge. Existing checkouts are reused as-is; the bootstrap does not switch their branches.

## Future structure

The current profile scripts are intentionally small. As the project grows, move stage execution policy into a dedicated dispatcher and introduce explicit contracts for stage prerequisites, produced state, rollback and idempotency. Avoid a generic plugin framework until there are enough real profiles to justify it.

Suggested future layout:

```text
installer/
  menu.sh
  main.sh
  dispatcher.sh
  runtime.sh
profiles/
  remnawave-standard/profile.sh
  remnawave-extended/profile.sh
  remnawave-cascade/entry.sh
  remnawave-cascade/exit-panel.sh
modules/
  common/
  remnawave/
  network/
  mtproxyl/
  haproxy/
  warp-masque/
```

Do not move existing modules merely to match this layout; perform such refactoring separately with regression coverage.


## eGamesAPI execution contract

The Remnawave stage pins eGamesAPI v3.8.4 to commit
`93e6631aae5f7bff28eadfc45faab43150cc22c6`. It fetches that exact Git commit,
checks out the complete repository (including its local `src/` modules), verifies
the commit ID, expected script version and Bash syntax, and only then launches
the interactive installer. This avoids running a floating installer from
`main` and lets the upstream script resolve its bundled modules from the pinned
checkout.

For the single-host standard and B-side profiles, the operator must select
`Install Remnawave Components → Install panel and node on one server` (menu
choices `1 → 1`). The stage then verifies that both `remnawave` and
`remnanode` containers are running. An installer exit code of zero alone is
not treated as proof of installation.

Upstream eGamesAPI documentation explicitly says the combined Panel + Node
mode is not recommended for production and recommends separate Panel-only /
Node-only modes. The installer shows this warning and requires an additional
confirmation. The combined flow also installs the subscription page and
reverse-proxy components. Review the upstream warning before using this profile
for a production deployment.

## Stage result contract

- `0`: completed successfully.
- `10`: skipped; accepted only for a stage listed in
  `PROFILE_OPTIONAL_STAGES`.
- Any other non-zero status: failure; abort the profile.

The standard profile has no optional stages. The extended and B-side profiles
currently mark MTProxyL, HAProxy integration and WARP/MASQUE as optional. The
system preparation and eGamesAPI stages are mandatory and abort on refusal.
