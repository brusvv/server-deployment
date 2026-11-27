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
        (fixture / "installer" / "lang").mkdir()
        (fixture / "profiles" / "remnawave-standard").mkdir(parents=True)
        (fixture / "profiles" / "remnawave-extended").mkdir(parents=True)
        (fixture / "profiles" / "remnawave-cascade").mkdir(parents=True)
        shutil.copy(ROOT / "installer" / "main.sh", fixture / "installer" / "main.sh")
        shutil.copy(ROOT / "installer" / "menu.sh", fixture / "installer" / "menu.sh")
        for lang in ("ru.sh", "en.sh"):
            shutil.copy(ROOT / "installer" / "lang" / lang, fixture / "installer" / "lang" / lang)
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
            SD_LANGUAGE="ru",
        )
        pid, fd = pty.fork()
        if pid == 0:
            if os.geteuid() != 0:
                os.execvpe("sudo", ["sudo", "-n", "env", f"TEST_STAGE_LOG={log}", f"TEST_FAIL_STAGE={fail_stage}", f"TEST_OPTIONAL_STAGES={optional_stages}", "SD_LANGUAGE=ru", "bash", str(fixture / "installer" / "main.sh")], env)
            os.execvpe("bash", ["bash", str(fixture / "installer" / "main.sh")], env)

        os.write(fd, inputs.encode())
        output = bytearray()
        status = None
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

        # The loop may already have reaped the child. A second waitpid()
        # then raises ChildProcessError; if it returns (0, 0), the child is
        # still running and we must wait for its real exit status. Never
        # overwrite a previously captured non-zero status with the WNOHANG
        # placeholder status 0.
        try:
            waited, final_status = os.waitpid(pid, os.WNOHANG)
            if waited == pid:
                status = final_status
            elif waited == 0:
                _, status = os.waitpid(pid, 0)
        except ChildProcessError:
            pass

        if status is None:
            raise AssertionError("installer child exit status was not collected")

        stages = log.read_text(encoding="utf-8").splitlines() if log.exists() else []
        return bytes(output).decode(errors="replace"), stages, os.waitstatus_to_exitcode(status)


def run_bridge_wizard(dry_run: bool = False):
    with tempfile.TemporaryDirectory(prefix="bridge-wizard-test-") as tmp:
        fixture = pathlib.Path(tmp)
        (fixture / "lib").mkdir()
        (fixture / "config").mkdir()
        (fixture / "bin").mkdir()
        shutil.copy(ROOT / "install.sh", fixture / "install.sh")
        shutil.copy(ROOT / "lib" / "common.sh", fixture / "lib" / "common.sh")
        shutil.copy(ROOT / "lib" / "config.sh", fixture / "lib" / "config.sh")
        (fixture / "config" / "ports.env").write_text(
            'SS_BRIDGE_ENABLED="0"\nSS_BRIDGE_PORT="9999"\nPUBLIC_HTTP_PORT="80"\n',
            encoding="utf-8",
        )
        (fixture / "config" / "services.env").write_text("", encoding="utf-8")
        (fixture / "bin" / "python3").write_text("#!/usr/bin/env bash\nexit 99\n", encoding="utf-8")
        (fixture / "bin" / "python3").chmod(0o755)
        env = os.environ.copy()
        env["PATH"] = str(fixture / "bin") + os.pathsep + env["PATH"]
        pid, fd = pty.fork()
        if pid == 0:
            args = ["bash", str(fixture / "install.sh")]
            if dry_run:
                args.append("--dry-run")
            args.append("--configure-bridge")
            os.execvpe("bash", args, env)
        os.write(fd, b"y\n24443\n")
        output = bytearray()
        deadline = time.time() + 10
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
            raise AssertionError("bridge wizard timed out")
        try:
            _, status = os.waitpid(pid, os.WNOHANG)
            if status is None:
                _, status = os.waitpid(pid, 0)
        except ChildProcessError:
            pass
        config = (fixture / "config" / "ports.env").read_text(encoding="utf-8")
        assert os.waitstatus_to_exitcode(status) == 0, bytes(output).decode(errors="replace")
        backups = list((fixture / "config").glob("ports.env.before-server-deployment.*"))
        if dry_run:
            assert 'SS_BRIDGE_ENABLED="0"' in config, config
            assert 'SS_BRIDGE_PORT="9999"' in config, config
            assert not backups, backups
        else:
            assert 'SS_BRIDGE_ENABLED="1"' in config, config
            assert 'SS_BRIDGE_PORT="24443"' in config, config
            assert 'PUBLIC_HTTP_PORT="80"' in config, config
            assert len(backups) == 1, backups


def assert_case(name, inputs, expected, *, fail="", optional="", expected_code=0, output_contains=()):
    output, stages, code = run_profile(inputs, fail, optional)
    assert stages == expected, f"{name}: stages {stages!r} != {expected!r}\n{output}"
    assert code == expected_code, f"{name}: exit {code} != {expected_code}\n{output}"
    for phrase in output_contains:
        assert phrase in output, f"{name}: missing output {phrase!r}\n{output}"


def main():
    assert_case(
        "standard",
        "1\n1\n1\n",
        ["preflight", "backup", "system", "remnawave", "validate"],
        output_contains=("SERVER DEPLOYMENT", "ГЛАВНОЕ МЕНЮ", "Установка", "СОСТОЯНИЕ СЕРВЕРА", "Одиночный сервер", "ПОДТВЕРЖДЕНИЕ УСТАНОВКИ", "До подтверждения изменения системы не выполняются"),
    )
    assert_case(
        "extended with optional skips",
        "1\n2\n1\n",
        ["preflight", "backup", "system", "remnawave", "adapter", "mtproxyl", "haproxy", "validate", "warp-masque"],
        optional="mtproxyl haproxy warp-masque",
        output_contains=("Расширенная установка", "Результат этапа mtproxyl: пропущен", "Результат этапа haproxy: пропущен", "Результат этапа warp-masque: пропущен"),
    )
    assert_case(
        "cascade Entry",
        "1\n3\n1\n1\n",
        ["preflight", "backup", "system", "validate"],
        output_contains=("КАСКАДНАЯ УСТАНОВКА", "VPS A — Entry", "VPS B — Panel + Exit"),
    )
    assert_case(
        "cascade Panel + Exit",
        "1\n3\n2\n1\n",
        ["preflight", "backup", "system", "remnawave", "adapter", "mtproxyl", "haproxy", "validate", "warp-masque"],
        optional="mtproxyl haproxy warp-masque",
        output_contains=("Профиль не следует считать полностью развёрнутым",),
    )
    assert_case(
        "mandatory stage failure stops profile",
        "1\n1\n1\n",
        ["preflight", "backup", "system", "remnawave"],
        fail="remnawave",
        expected_code=42,
        output_contains=("профиль остановлен",),
    )
    assert_case(
        "decline profile confirmation",
        "1\n1\n2\n0\n",
        [],
        output_contains=("Установщик закрыт",),
    )
    run_bridge_wizard()
    run_bridge_wizard(dry_run=True)
    print("Installer menu, profile orchestration and bridge wizard tests passed.")


if __name__ == "__main__":
    main()
