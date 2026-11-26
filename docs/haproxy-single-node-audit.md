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
