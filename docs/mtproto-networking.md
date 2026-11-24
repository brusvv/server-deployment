# MTProto on VPS B — network model

## The important distinction

MTProto has a client-facing listener and it makes outbound connections to Telegram, but it does **not** need a pair of Xray inbound/outbound objects or a second Remnawave Exit Node.

One Telemt/MTProxy process handles both sides:

```text
Telegram app
    |
    | MTProto over TCP (server + port + secret)
    v
VPS B — public TCP 443
    |
    v
HAProxy TCP/SNI frontend
    |
    | selected MTProto/default backend
    v
Telemt listener (historical backend: 127.0.0.1:15443/tcp)
    |
    | outbound TCP connections
    v
Telegram DC infrastructure
```

The exact HAProxy routing and Telemt bind must be taken from the current active configuration. The `15443` backend is only a historical reference from `docs/validated-server-baseline-2026-11-18.md`; it must not be assumed to remain active after OS reinstall.

## What MTProto does and does not require

| Item | Needed? | Notes |
|---|---|---|
| Client-facing listener | Yes | Telemt accepts client connections on its configured server port/listener |
| Client secret | Yes | Telegram proxy links contain server, port and secret |
| Outbound access to Telegram DCs | Yes | The proxy relays traffic to Telegram's DC infrastructure |
| Separate Remnawave Exit Node | No | Telemt itself is the proxy endpoint |
| Xray Shadowsocks inbound/outbound pair | No | The A → B bridge is unrelated to MTProto |
| VLESS Route / `vlessRouteId` | No | Not part of MTProto |
| UDP listener for the MTProto proxy | Not part of the planned Telemt listener path | Keep the Telemt public service path TCP; the Shadowsocks bridge separately uses TCP + UDP |

The precise wording is therefore: MTProto does have a network ingress and egress, but it does not have separately provisioned Xray “inbound” and “outbound” objects or a separate exit server.

## Port ownership for this project

| Port | Bind / owner | Purpose |
|---|---|---|
| `443/tcp` | Public HAProxy on B | Shared public TCP/SNI ingress; route MTProto to Telemt according to active HAProxy config |
| `15443/tcp` | Historical `127.0.0.1` Telemt backend | Keep loopback-only if the current HAProxy config expects it |
| `9091/tcp` | Telemt API, loopback | Management API; do not expose publicly |
| `9090/tcp` | Optional Telemt metrics, loopback | Monitoring only; enable only if needed |
| `9999/tcp+udp` | Proposed Xray SS bridge listener on B | Separate A → B Remnawave data plane; not MTProto |

HAProxy stays the public owner of TCP 80/443. Do not start a second process that binds public TCP 443 while HAProxy owns it. Do not route the SS bridge through the Telemt backend.

## Network and firewall expectations

- Inbound from Telegram clients reaches B through the configured HAProxy route. Preserve the current SNI/default-backend behavior only after auditing the active configuration.
- Telemt must be able to establish outbound connections to Telegram's DC infrastructure. Do not hard-code one guessed DC address or route this egress through the A → B SS bridge.
- Keep Telemt's API and metrics bound to loopback unless a separately reviewed monitoring design requires otherwise.
- Keep the MTProto user secrets out of Git, shell history, chat transcripts and audit output.
- If the active HAProxy configuration uses a PROXY protocol, verify that Telemt's `proxy_protocol` setting matches it. Do not enable or disable it by assumption.

## Telemt settings to inspect

The upstream Telemt sample config exposes:

- `[server]` listener configuration and `server.port`;
- optional `[server.api]` listener, normally loopback;
- optional metrics listener and whitelist;
- enabled MTProto modes under `[general.modes]`;
- masking/TLS-fronting options under `[censorship]`;
- per-user secrets under `[access.users]`.

The exact installed Telemt version and its supported options must be checked before writing configuration. The repository's sample config is a reference, not a drop-in config for the existing MTProxyL deployment.

## References

- Telegram MTProxy official documentation: https://core.telegram.org/proxy
- Official Telegram MTProxy implementation: https://github.com/TelegramMessenger/MTProxy
- Telemt project and configuration: https://github.com/telemt/telemt
- Telemt config sample: https://github.com/telemt/telemt/blob/main/config.toml
- Telemt FAQ (including DC reachability): https://github.com/telemt/telemt/blob/main/docs/FAQ.ru.md

This is a network design note. It does not install, expose, or modify a Telemt listener.
