#!/usr/bin/env python3
"""Apply a narrow, fail-closed eGamesAPI Panel+local-Exit compatibility patch.

The patch only relaxes SR_SAME_BOX when the selected host already resolves to a
registered, connected Node with a readable active profile. It never provisions
a Node or changes Panel objects, firewall rules, or Xray profiles.
"""
from __future__ import annotations

import argparse
import datetime as dt
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ORIGINAL = r'''    if [ -n "$panel_ip" ] && { [ "$host" = "$panel_ip" ] || [ "$host_ip" = "$panel_ip" ]; }; then
        echo -e "${COLOR_RED}${LANG[SR_SAME_BOX]}${COLOR_RESET}"
        return 1
    fi'''

PATCHED = r'''    if [ -n "$panel_ip" ] && { [ "$host" = "$panel_ip" ] || [ "$host_ip" = "$panel_ip" ]; }; then
        # Permit Panel + Exit co-location only for an existing, connected Node.
        # Never let an unknown host fall through to the remote-node installer.
        if ! sr_find_node_by_host "$host" \
           || [ "$SR_NODE_CONNECTED" != "true" ] \
           || [ -z "$SR_NODE_UUID" ] \
           || [ -z "$SR_NODE_PROFILE" ]; then
            echo -e "${COLOR_RED}${LANG[SR_SAME_BOX]}${COLOR_RESET}"
            return 1
        fi
        echo -e "${COLOR_GREEN}[ ✓ ]${COLOR_RESET} Reusing the existing connected local Node."
    fi'''

def backup_path(target: Path) -> Path:
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    candidate = target.with_name(target.name + f".before-server-deployment.{stamp}")
    suffix = 1
    while candidate.exists():
        candidate = target.with_name(
            target.name + f".before-server-deployment.{stamp}.{suffix}"
        )
        suffix += 1
    return candidate

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--check", action="store_true", help="check patch context only (read-only)")
    action.add_argument("--apply", action="store_true", help="apply after typed confirmation")
    parser.add_argument("module", type=Path, help="absolute path to eGamesAPI server_routing.sh")
    args = parser.parse_args()

    target = args.module
    if not target.is_absolute():
        parser.error("module path must be absolute")
    if target.is_symlink() or not target.is_file():
        print(f"ERROR: refusing missing file or symlink: {target}", file=sys.stderr)
        return 2

    try:
        original_text = target.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        print(f"ERROR: cannot read module: {exc}", file=sys.stderr)
        return 2

    if original_text.count(PATCHED) == 1:
        print(f"OK: compatibility patch is already present: {target}")
        return 0
    if PATCHED in original_text:
        print("ERROR: patched context appears more than once; refusing ambiguity.", file=sys.stderr)
        return 2
    count = original_text.count(ORIGINAL)
    if count != 1:
        print(
            f"ERROR: expected exactly one known SR_SAME_BOX block, found {count}. "
            "The installed eGamesAPI module differs; no changes made.",
            file=sys.stderr,
        )
        return 2

    print("OK: exact eGamesAPI same-box guard found.")
    print("The proposed exception requires a matching registered Node, active profile, and connected state.")
    if args.check:
        print("CHECK ONLY: no file or backup was changed.")
        return 0

    print(f"Target: {target}")
    try:
        answer = input("Type APPLY to create a backup and patch this module: ")
    except EOFError:
        answer = ""
    if answer != "APPLY":
        print("Cancelled; no changes made.")
        return 0

    new_text = original_text.replace(ORIGINAL, PATCHED, 1)
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
        print("No Node, profile, inbound, firewall, or service was changed.")
        return 0
    except Exception as exc:  # keep the original module untouched on pre-replace failures
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
