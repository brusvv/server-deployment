# Installer validation plan

Branch: `feature/remnawave-fingerprint-hardening`

This plan separates automated repository tests from real host integration tests. A green CI run proves the mocked menu/dispatcher and local regression tests; it does not prove that eGamesAPI, Docker, Panel, Xray, MTProxyL or HAProxy can be deployed successfully on a live VPS.

## 1. Installation paths and expected stage order

| Menu path | Required stages | Optional stages | What the path actually delivers |
|---|---|---|---|
| Standard Remnawave | `preflight → backup → system → remnawave → validate` | — | eGamesAPI combined Panel + local Node, bundled subscription/reverse-proxy components, Nginx version hardening |
| Extended Remnawave | `preflight → backup → system → remnawave → adapter → mtproxyl → haproxy → validate → warp-masque` | `mtproxyl`, `haproxy`, `warp-masque` | Standard Panel + Node plus guided Xray/HAProxy hand-off and optional MTProxyL, HAProxy integration and WARP/MASQUE |
| Cascade — VPS A / Entry | `preflight → backup → system → validate` | — | Host preparation only. It does **not** install/register a Remnawave Node, create a VLESS inbound or configure A → B routing |
| Cascade — VPS B / Panel + Exit | `preflight → backup → system → remnawave → adapter → mtproxyl → haproxy → validate → warp-masque` | `mtproxyl`, `haproxy`, `warp-masque` | Panel + local Exit Node and the optional B-side MTProxyL/HAProxy/WARP components. It does **not** create the live A/B Shadowsocks bridge |

The standard and B-side profiles use eGamesAPI's combined Panel + Node installer choice **1 → 1**. Upstream documents this combined mode as not recommended for production; production deployments should evaluate separate Panel-only and Node-only installation.

The `adapter` stage is currently a guided/manual hand-off. It reports the expected Xray loopback endpoint and fallback socket; it does not edit a Remnawave Config Profile. The live Entry/Exit bridge is a separate eGamesAPI Server Routing workflow and requires explicit operator action.

## 2. Automated checks

Run from the repository root:

```bash
bash tests/shellcheck.sh
```

The suite covers:

- Bash syntax and ShellCheck for shell scripts.
- Config parsing and port discovery.
- eGamesAPI compatibility adapters and their idempotence.
- Nginx hardening helper behavior, including backup, validation, rollback guards and nested directive handling.
- Installer menu/dispatcher integration using a pseudo-terminal and a fake stage runner:
  - Standard profile completes its required stage sequence.
  - Extended profile continues after optional stages return the skip code.
  - Cascade A selects only its preparation stages.
  - Cascade B selects the Panel + Exit sequence and reports optional skips.
  - A mandatory stage failure stops the profile immediately.
  - Declining profile confirmation returns to the menu without running stages.
- Check-only/dry-run logging contract: `--check` and dry-run do not create log directories/files; consecutive stage invocations create separate protected logs even within one second.
- Preflight domain validation rejects malformed hostnames and case-insensitive duplicates in the SNI/WEB and redirect lists; redirect hostnames are also included in DNS checks. A hostname may intentionally appear in both lists.\n- Preflight port validation rejects malformed/out-of-range public ports, duplicate HTTP/HTTPS ports and bridge/public-port collisions. If `ss` is unavailable before the System stage installs `iproute2`, preflight reports that occupancy checks were skipped rather than claiming ports are free.
- Bridge-settings wizard is exercised in normal and `--dry-run` modes; the test stubs Python to prove the writer uses only the base shell utilities.
- Backup-stage dry-run reports the planned paths without creating a backup directory or archive.

These tests do not execute privileged package installation or the external eGamesAPI installer.

## 3. Per-path host integration tests

Use disposable Debian/Ubuntu VMs, not production VPS A/B. Take provider snapshots first. Test each path from a clean VM and repeat once on a VM with the intended components already present to expose non-idempotent behavior.

### 3.1 Standard Remnawave

1. Bootstrap the exact feature branch and verify the checkout ref.
2. Create a host-specific `config/domains.env`; run `sudo ./install.sh --check`.
3. Confirm preflight rejects unsupported OS, malformed domains, case-insensitive duplicates, invalid redirect hostnames, invalid bridge settings and malformed/out-of-range/duplicate public ports; DNS/occupied public ports are reported as warnings and need operator review. If `ss` is unavailable on a minimal image, confirm preflight explicitly skips socket occupancy checks and System later installs `iproute2`.
4. Confirm the backup stage archives existing configured paths and local config before system preparation.
5. Confirm the system stage asks before installing packages and creates protected state/log/backup directories.
6. Confirm eGamesAPI consent is required; test refusal and verify the profile stops.
7. On an approved disposable VM, run eGamesAPI choice **1 → 1**. Verify `remnawave`, `remnawave-db`, `remnawave-redis`, `remnawave-nginx`, `remnawave-subscription-page` and `remnanode` are running; require healthy status for Panel, DB and Redis. Capture each image ref, image ID and repository digest.
8. Verify the generated `/opt/remnawave/nginx.conf` is backed up, has top-level `server_tokens off;`, passes `nginx -t`, and reloads only `remnawave-nginx`.
9. Verify the public HTTP `Server` header no longer exposes the Nginx version. Separately verify the Panel subscription response headers and subscription-page branding.
10. Re-run the Nginx hardening helper and confirm it makes no second backup/reload when already compliant.

### 3.2 Extended Remnawave

1. Complete the standard required stages.
2. Verify the adapter stage clearly states that Xray profile editing is manual and does not claim it has changed the profile.
3. Test MTProxyL absent, installer path invalid, operator declines, installer succeeds and installer fails.
4. Test HAProxy absent, wrong systemd unit/config/binary, inactive service, Xray listener missing, other backend listeners missing, invalid candidate, operator declines, successful reload and failed reload/rollback.
5. A pending HAProxy plan must be reported as **skipped**, not successful; no active config replacement/reload is allowed while backends are not ready.
6. Test WARP/MASQUE declined, non-interactive default skip, successful registration on a disposable Panel, and registration/profile update failure.
7. Confirm each optional skip is explicit in the final profile summary and is not represented as a completed deployment.

### 3.3 Cascade — VPS A / Entry

1. Verify menu selection and confirmation.
2. Verify only preflight, backup, system and validation run.
3. Verify no eGamesAPI installer, Docker deployment, Node registration, VLESS inbound, bridge inbound/outbound, routing or firewall mutation is attempted.
4. Confirm documentation labels this as **A host preparation**, not a completed Entry deployment.
5. Separately design and test the later Node installation/registration and A → B routing procedure before treating this role as production-ready.

### 3.4 Cascade — VPS B / Panel + Exit

1. Verify menu selection and confirmation.
2. Run the standard Panel + Node and Nginx hardening acceptance tests.
3. Verify adapter remains a manual hand-off.
4. Test the optional MTProxyL/HAProxy/WARP branches as in the extended profile.
5. Verify no automatic Shadowsocks inbound, service user/squad, Entry outbound, routing or firewall allowlist is created.
6. Test the B-side same-host Exit compatibility patch against the exact pinned eGamesAPI module: check-only, apply, repeat apply, source mismatch refusal and restore from backup.
7. On a separate two-VM test network, validate TCP **and** UDP bridge transport, A-source-only firewall restriction, correct direct Geo Bridge policy, actual foreign egress and teardown ordering.

## 4. CLI and bootstrap matrix

| Invocation | Expected behavior |
|---|---|
| `bash <(curl .../install.sh)` with no arguments and a TTY | Clone the requested ref, then open the profile menu |
| `SD_GIT_REF=feature/remnawave-fingerprint-hardening bash <(curl .../install.sh)` | Bootstrap this feature branch; refuse to silently switch an existing checkout on another branch |
| `sudo ./install.sh` with a TTY | Open the profile menu |
| `sudo ./install.sh` without a TTY | Check-only preflight; no install |
| `sudo ./install.sh --check` | Read-only preflight; no package/service/config changes and no log-file creation |
| `sudo ./install.sh --configure-bridge` | Change only local bridge settings after confirmation; no live bridge mutation |
| `sudo ./install.sh --dry-run --configure-bridge` | Show the bridge choices but do not write the local config or create a backup |
| `sudo ./install.sh --run --dry-run --stage backup` | Report which paths would be backed up; do not create an archive |
| `sudo ./install.sh --run --stage NAME` | Execute exactly one named stage with its own confirmation/safety gates |
| `sudo ./install.sh --run` | Legacy all-stage flow with the bridge-settings prompt; not the profile menu |

Test bootstrap against a fresh directory, an existing checkout on the requested branch, an existing checkout on a different branch and a non-repository path at `SD_INSTALL_DIR`.

## 5. Stop conditions

Stop the test and preserve logs/backups if any of the following occurs:

- eGamesAPI source commit or expected script version differs from the pin.
- The expected Panel/Node/Nginx containers are absent or have unexpected names.
- Nginx validation fails or the helper cannot restore the original file.
- HAProxy candidate validation fails, active service identity differs from the configured unit/config/binary, or rollback reload fails.
- A required stage returns non-zero.
- An optional stage returns a failure other than the documented skip code.
- Any path unexpectedly changes a Remnawave profile, firewall or live bridge state.

## 6. Current test status

- **Automated profile/dispatcher simulation:** covered by the pseudo-terminal test matrix; no real service is installed by this test.
- **Shell/config/adapter regression tests:** run in CI.
- **Live Debian/Ubuntu installation paths:** not yet executed.
- **eGamesAPI + Docker + Panel integration:** not yet executed on a disposable VM.
- **Two-VPS A → B transport, firewall, routing and teardown:** not yet executed.
- **Public header and subscription branding verification:** not yet executed against a live Panel.

Do not mark the installer fully accepted until all four paths have passed their disposable-VM integration checks and the separate two-VPS bridge test has passed.
