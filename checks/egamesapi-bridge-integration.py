#!/usr/bin/env python3
"""Connect server-deployment bridge settings to eGamesAPI Server Routing.

Requires the separate, narrow local-Exit compatibility patch to be present.
The adapter reads only SS_BRIDGE_ENABLED and SS_BRIDGE_PORT from config/ports.env.
It blocks new setup/attachment while disabled, but leaves teardown available.
"""
from __future__ import annotations

import argparse
import datetime as dt
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile

BEGIN = "# BEGIN SERVER_DEPLOYMENT_BRIDGE_CONFIG"
END = "# END SERVER_DEPLOYMENT_BRIDGE_CONFIG"
PORT_LINE = "SR_DEFAULT_PORT=9999"
SETUP_ANCHOR = "sr_setup() {"
ATTACH_ANCHOR = "sr_attach_profile() {"
ATTACH_STATE_PORT_BLOCK = """    if [ -z "$host" ] || [ -z "$port" ] || [ -z "$password" ]; then
        echo -e "${COLOR_RED}${LANG[SR_ATTACH_NOT_READY]}${COLOR_RESET}"
        return 1
    fi

    ru_list=$(sr_state_get ru_profiles)"""
ATTACH_PORT_MARKER = "SERVER_DEPLOYMENT_MANAGED_BRIDGE_ATTACH_PORT_CHECK"
ASKED_PORT_LINE = '    ss_port="$SR_ASKED_PORT"'
SETUP_MARKER = "SERVER_DEPLOYMENT_MANAGED_BRIDGE_SETUP_GUARD"
ATTACH_MARKER = "SERVER_DEPLOYMENT_MANAGED_BRIDGE_ATTACH_GUARD"
PORT_MARKER = "SERVER_DEPLOYMENT_MANAGED_BRIDGE_PORT_CHECK"

SAME_BOX_SIGNATURES = (
    'if ! sr_find_node_by_host "$host"',
    '[ "$SR_NODE_CONNECTED" != "true" ]',
    '[ -z "$SR_NODE_UUID" ]',
    '[ -z "$SR_NODE_PROFILE" ]',
    "Reusing the existing connected local Node.",
)

def validate_config(path: Path) -> tuple[str, int]:
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"bridge config is missing, not regular, or a symlink: {path}")
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as exc:
        raise ValueError(f"cannot read bridge config: {exc}") from exc

    values: dict[str, list[str]] = {"SS_BRIDGE_ENABLED": [], "SS_BRIDGE_PORT": []}
    for line in lines:
        for key in values:
            prefix = key + "="
            if line.startswith(prefix):
                raw = line[len(prefix):]
                if len(raw) < 2 or raw[0] != '"' or raw[-1] != '"':
                    raise ValueError(f'{key} must use the quoted format in config/ports.env')
                values[key].append(raw[1:-1])

    for key, entries in values.items():
        if len(entries) != 1:
            raise ValueError(f"expected exactly one {key} entry, found {len(entries)}")

    enabled = values["SS_BRIDGE_ENABLED"][0]
    if enabled not in ("0", "1"):
        raise ValueError("SS_BRIDGE_ENABLED must be 0 or 1")

    port_text = values["SS_BRIDGE_PORT"][0]
    if not port_text.isascii() or not port_text.isdigit() or len(port_text) > 5:
        raise ValueError("SS_BRIDGE_PORT must be a decimal integer from 1 to 65535")
    port = int(port_text, 10)
    if not 1 <= port <= 65535:
        raise ValueError("SS_BRIDGE_PORT must be from 1 to 65535")
    if port == 2222:
        raise ValueError("SS_BRIDGE_PORT 2222 is reserved for the eGamesAPI node control port")
    return enabled, port

def build_block(config_file: Path) -> str:
    config_literal = shlex.quote(str(config_file))
    return f'''{BEGIN}
# Read only the two bridge settings; never source/execute config/ports.env.
SR_SD_BRIDGE_CONFIG={config_literal}
sr_sd_load_bridge_config() {{
    local file="$SR_SD_BRIDGE_CONFIG" enabled_count port_count enabled port port_value
    if [ -L "$file" ] || [ ! -f "$file" ]; then
        echo "ERROR: server-deployment bridge config is unavailable: $file" >&2
        return 1
    fi
    enabled_count="$(grep -c '^SS_BRIDGE_ENABLED=' "$file" || true)"
    port_count="$(grep -c '^SS_BRIDGE_PORT=' "$file" || true)"
    if [ "$enabled_count" != "1" ] || [ "$port_count" != "1" ]; then
        echo "ERROR: expected exactly one SS_BRIDGE_ENABLED and SS_BRIDGE_PORT in $file" >&2
        return 1
    fi
    enabled="$(sed -n 's/^SS_BRIDGE_ENABLED="\([01]\)"$/\1/p' "$file")"
    port="$(sed -n 's/^SS_BRIDGE_PORT="\([0-9][0-9]*\)"$/\1/p' "$file")"
    case "$enabled" in
        0|1) ;;
        *) echo "ERROR: SS_BRIDGE_ENABLED must be 0 or 1" >&2; return 1 ;;
    esac
    case "$port" in
        ''|*[!0-9]*) echo "ERROR: SS_BRIDGE_PORT must be numeric" >&2; return 1 ;;
    esac
    if [ "$(printf '%s' "$port" | wc -c)" -gt 5 ]; then
        echo "ERROR: SS_BRIDGE_PORT must be from 1 to 65535" >&2
        return 1
    fi
    port_value=$((10#$port))
    if (( port_value < 1 || port_value > 65535 || port_value == 2222 )); then
        echo "ERROR: SS_BRIDGE_PORT must be 1..65535, except reserved port 2222" >&2
        return 1
    fi
    SR_SD_BRIDGE_ENABLED="$enabled"
    SR_SD_BRIDGE_PORT="$port_value"
    SR_DEFAULT_PORT="$port_value"
    return 0
}}

sr_sd_require_bridge_enabled() {{
    sr_sd_load_bridge_config || return 1
    if [ "$SR_SD_BRIDGE_ENABLED" != "1" ]; then
        echo "Shadowsocks bridge is disabled in server-deployment config; setup/attach is blocked." >&2
        echo "Teardown remains available from the eGamesAPI Server Routing menu." >&2
        return 1
    fi
    return 0
}}

sr_sd_require_selected_port() {{
    local selected_port="$1"
    sr_sd_require_bridge_enabled || return 1
    if [ "$selected_port" != "$SR_SD_BRIDGE_PORT" ]; then
        echo "Selected port $selected_port differs from SS_BRIDGE_PORT=$SR_SD_BRIDGE_PORT." >&2
        echo "Change config/ports.env and rerun setup; the bridge has one source of truth." >&2
        return 1
    fi
    return 0
}}
{END}'''

def backup_path(target: Path) -> Path:
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    candidate = target.with_name(target.name + f".before-server-deployment.{stamp}")
    suffix = 1
    while candidate.exists():
        candidate = target.with_name(target.name + f".before-server-deployment.{stamp}.{suffix}")
        suffix += 1
    return candidate

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--check", action="store_true", help="check exact patch context only")
    action.add_argument("--apply", action="store_true", help="apply after typed confirmation")
    parser.add_argument("--config-file", type=Path, required=True,
                        help="absolute path to server-deployment config/ports.env")
    parser.add_argument("module", type=Path, help="absolute path to eGamesAPI server_routing.sh")
    args = parser.parse_args()

    target, config_file = args.module, args.config_file
    if not target.is_absolute() or not config_file.is_absolute():
        parser.error("module and config-file paths must be absolute")
    if target.is_symlink() or not target.is_file():
        print(f"ERROR: refusing missing module or symlink: {target}", file=sys.stderr)
        return 2

    try:
        enabled, port = validate_config(config_file)
        original_text = target.read_text(encoding="utf-8")
    except (OSError, UnicodeError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    missing = [signature for signature in SAME_BOX_SIGNATURES if signature not in original_text]
    if missing:
        print("ERROR: local-Exit compatibility patch must be applied first.", file=sys.stderr)
        print("Run checks/egamesapi-local-exit-compat.py --check/--apply before this adapter.", file=sys.stderr)
        return 2

    expected_block = build_block(config_file)
    markers_present = BEGIN in original_text or END in original_text
    if markers_present:
        if (original_text.count(BEGIN) == 1 and original_text.count(END) == 1
                and expected_block in original_text
                and original_text.count(SETUP_MARKER) == 1
                and original_text.count(ATTACH_MARKER) == 1
                and original_text.count(PORT_MARKER) == 1
                and original_text.count(ATTACH_PORT_MARKER) == 1):
            print(f"OK: managed bridge configuration adapter is already present: {target}")
            print(f"Config source: {config_file} (enabled={enabled}, port={port})")
            return 0
        print("ERROR: a partial or different server-deployment adapter is present; refusing to stack patches.", file=sys.stderr)
        return 2

    required = {
        PORT_LINE: original_text.count(PORT_LINE),
        SETUP_ANCHOR: original_text.count(SETUP_ANCHOR),
        ATTACH_ANCHOR: original_text.count(ATTACH_ANCHOR),
        ASKED_PORT_LINE: original_text.count(ASKED_PORT_LINE),
        ATTACH_STATE_PORT_BLOCK: original_text.count(ATTACH_STATE_PORT_BLOCK),
    }
    bad = {key: count for key, count in required.items() if count != 1}
    if bad:
        print("ERROR: unexpected eGamesAPI source context; no changes made.", file=sys.stderr)
        for key, count in bad.items():
            print(f"  expected one {key!r}, found {count}", file=sys.stderr)
        return 2

    print("OK: local-Exit guard and exact setup/attach/port contexts found.")
    print(f"Config source: {config_file} (enabled={enabled}, port={port})")
    print("When disabled, setup and attach will be blocked; eGamesAPI teardown stays available.")
    if args.check:
        print("CHECK ONLY: no file or backup was changed.")
        return 0

    print(f"Target: {target}")
    try:
        answer = input("Type APPLY to back up and patch eGamesAPI Server Routing: ")
    except EOFError:
        answer = ""
    if answer != "APPLY":
        print("Cancelled; no changes made.")
        return 0

    new_text = original_text.replace(PORT_LINE, PORT_LINE + "\n" + expected_block, 1)
    new_text = new_text.replace(
        SETUP_ANCHOR,
        SETUP_ANCHOR + "\n    # " + SETUP_MARKER + "\n    sr_sd_require_bridge_enabled || return 1",
        1,
    )
    new_text = new_text.replace(
        ATTACH_ANCHOR,
        ATTACH_ANCHOR + "\n    # " + ATTACH_MARKER + "\n    sr_sd_require_bridge_enabled || return 1",
        1,
    )
    new_text = new_text.replace(
        ATTACH_STATE_PORT_BLOCK,
        ATTACH_STATE_PORT_BLOCK + "\n    # " + ATTACH_PORT_MARKER + "\n    sr_sd_require_selected_port \"$port\" || return 1",
        1,
    )
    new_text = new_text.replace(
        ASKED_PORT_LINE,
        ASKED_PORT_LINE + "\n    # " + PORT_MARKER + "\n    sr_sd_require_selected_port \"$ss_port\" || return 1",
        1,
    )

    st = target.stat()
    temp_name = None
    backup = backup_path(target)
    try:
        shutil.copy2(target, backup)
        fd, temp_name = tempfile.mkstemp(prefix=target.name + ".tmp.", dir=str(target.parent))
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as handle:
            handle.write(new_text)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temp_name, st.st_mode & 0o7777)
        try:
            os.chown(temp_name, st.st_uid, st.st_gid)
        except PermissionError:
            pass
        syntax = subprocess.run(
            ["bash", "-n", temp_name],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        if syntax.returncode != 0:
            raise RuntimeError("patched module failed bash -n: " + syntax.stderr.strip())
        os.replace(temp_name, target)
        temp_name = None
        print(f"APPLIED: {target}")
        print(f"BACKUP: {backup}")
        print("No Remnawave profile, node, user, squad, firewall, or service was changed.")
        return 0
    except Exception as exc:
        print(f"ERROR: patch failed: {exc}", file=sys.stderr)
        print("The original module was not replaced.", file=sys.stderr)
        if backup.exists():
            print(f"Backup retained: {backup}", file=sys.stderr)
        return 1
    finally:
        if temp_name:
            try:
                os.unlink(temp_name)
            except OSError:
                pass

if __name__ == "__main__":
    raise SystemExit(main())
