#!/usr/bin/env python3
"""Exercise the real profile menu and installer dispatcher with a fake stage runner."""
from __future__ import annotations

import os
import pathlib
import pty
import shutil
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent


def run_profile(inputs: str, fail_stage: str = "", optional_stages: str = ""):
    with tempfile.TemporaryDirectory(prefix="installer-profile-test-") as tmp:
        fixture = pathlib.Path(tmp)
        (fixture / "installer").mkdir()
        (fixture / "profiles" / "remnawave-standard").mkdir(parents=True)
        (fixture / "profiles" / "remnawave-extended").mkdir(parents=True)
        (fixture / "profiles" / "remnawave-cascade").mkdir(parents=True)
        shutil.copy(ROOT / "installer" / "main.sh", fixture / "installer" / "main.sh")
        shutil.copy(ROOT / "installer" / "menu.sh", fixture / "installer" / "menu.sh")
        for rel in (
            "profiles/remnawave-standard/profile.sh",
            "profiles/remnawave-extended/profile.sh",
            "profiles/remnawave-cascade/entry.sh",
            "profiles/remnawave-cascade/exit-panel.sh",
        ):
            shutil.copy(ROOT / rel, fixture / rel)

        log = fixture / "stages.log"
        runner = fixture / "install.sh"
        runner.write_text(
            """#!/usr/bin/env bash
set -Eeuo pipefail
stage=''
while (($#)); do
  case "$1" in
    --stage) shift; stage="$1" ;;
  esac
  shift
done
printf '%s\\n' "$stage" >> "$TEST_STAGE_LOG"
if [[ "$stage" == "$TEST_FAIL_STAGE" && -n "$TEST_FAIL_STAGE" ]]; then exit 42; fi
case " $TEST_OPTIONAL_STAGES " in
  *" $stage "*) exit 10 ;;
esac
exit 0
""",
            encoding="utf-8",
        )
        runner.chmod(0o755)

        env = os.environ.copy()
        env.update(
            TEST_STAGE_LOG=str(log),
            TEST_FAIL_STAGE=fail_stage,
            TEST_OPTIONAL_STAGES=optional_stages,
        )
        pid, fd = pty.fork()
        if pid == 0:
            if os.geteuid() != 0:
                os.execvpe("sudo", ["sudo", "-E", "-n", "bash", str(fixture / "installer" / "main.sh")], env)
            os.execvpe("bash", ["bash", str(fixture / "installer" / "main.sh")], env)

        os.write(fd, inputs.encode())
        output = bytearray()
        deadline = time.time() + 15
        while time.time() < deadline:
            try:
                chunk = os.read(fd, 4096)
                if not chunk:
                    break
                output.extend(chunk)
            except OSError:
                break
            waited, status = os.waitpid(pid, os.WNOHANG)
            if waited == pid:
                break
        else:
            os.kill(pid, 9)
            raise AssertionError("installer menu timed out")

        try:
            _, status = os.waitpid(pid, os.WNOHANG)
            if status is None:
                _, status = os.waitpid(pid, 0)
        except ChildProcessError:
            pass

        stages = log.read_text(encoding="utf-8").splitlines() if log.exists() else []
        return bytes(output).decode(errors="replace"), stages, os.waitstatus_to_exitcode(status)


def assert_case(name, inputs, expected, *, fail="", optional="", expected_code=0, output_contains=()):
    output, stages, code = run_profile(inputs, fail, optional)
    assert stages == expected, f"{name}: stages {stages!r} != {expected!r}\n{output}"
    assert code == expected_code, f"{name}: exit {code} != {expected_code}\n{output}"
    for phrase in output_contains:
        assert phrase in output, f"{name}: missing output {phrase!r}\n{output}"


def main():
    assert_case(
        "standard",
        "1\n1\n",
        ["preflight", "backup", "system", "remnawave", "validate"],
    )
    assert_case(
        "extended with optional skips",
        "2\n1\n",
        ["preflight", "backup", "system", "remnawave", "adapter", "mtproxyl", "haproxy", "validate", "warp-masque"],
        optional="mtproxyl haproxy warp-masque",
        output_contains=("этап mtproxyl: пропущен", "этап haproxy: пропущен", "этап warp-masque: пропущен"),
    )
    assert_case(
        "cascade Entry",
        "3\n1\n1\n",
        ["preflight", "backup", "system", "validate"],
    )
    assert_case(
        "cascade Panel + Exit",
        "3\n2\n1\n",
        ["preflight", "backup", "system", "remnawave", "adapter", "mtproxyl", "haproxy", "validate", "warp-masque"],
        optional="mtproxyl haproxy warp-masque",
        output_contains=("Профиль не следует считать полностью развёрнутым",),
    )
    assert_case(
        "mandatory stage failure stops profile",
        "1\n1\n",
        ["preflight", "backup", "system", "remnawave"],
        fail="remnawave",
        expected_code=42,
        output_contains=("профиль остановлен",),
    )
    assert_case(
        "decline profile confirmation",
        "1\n2\n0\n",
        [],
        output_contains=("Установщик закрыт",),
    )
    print("Installer menu and profile orchestration tests passed.")


if __name__ == "__main__":
    main()
