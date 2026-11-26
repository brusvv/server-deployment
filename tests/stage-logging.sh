#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() { if [[ "$EUID" == 0 ]]; then rm -rf -- "$tmp"; else sudo -n rm -rf -- "$tmp"; fi; }
trap cleanup EXIT
fixture="$tmp/repo"
log_dir="$tmp/logs"
mkdir -p "$fixture/lib" "$fixture/config" "$fixture/modules"
cp "$ROOT/install.sh" "$fixture/install.sh"
cp "$ROOT/lib/common.sh" "$ROOT/lib/config.sh" "$fixture/lib/"
cat > "$fixture/config/ports.env" <<'EOF'
PUBLIC_HTTP_PORT="80"
PUBLIC_HTTPS_PORT="443"
SS_BRIDGE_ENABLED="0"
SS_BRIDGE_PORT="9999"
EOF
cat > "$fixture/config/services.env" <<'EOF'
BACKUP_DIR="/tmp/unused-backups"
STATE_DIR="/tmp/unused-state"
EOF
cat > "$fixture/config/domains.env" <<'EOF'
REMNAWAVE_SNI_DOMAINS="panel.example.com"
WEB_DOMAIN="web.example.net"
EOF
cat > "$fixture/modules/00-preflight.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source "$SD_ROOT/lib/common.sh"
info "MODULE_INFO_MARKER"
printf 'MODULE_STDOUT_MARKER\n'
printf 'MODULE_STDERR_MARKER\n' >&2
if [[ "${FAIL_STAGE:-0}" == "1" ]]; then
  printf 'MODULE_FAILURE_MARKER\n' >&2
  exit 42
fi
EOF
chmod +x "$fixture/modules/00-preflight.sh"

as_root() {
  if [[ "$EUID" == 0 ]]; then "$@"; else sudo -n "$@"; fi
}
run_installer() {
  as_root env SD_LOG_DIR="$log_dir" "$@" bash "$fixture/install.sh" --run --stage preflight
}

run_installer
mapfile -t logs < <(as_root find "$log_dir" -maxdepth 1 -type f -name 'run-*.log' | sort)
[[ "${#logs[@]}" -eq 1 ]] || { echo "Expected one stage log, found ${#logs[@]}" >&2; exit 1; }
for marker in "===== preflight =====" "MODULE_INFO_MARKER" "MODULE_STDOUT_MARKER" "MODULE_STDERR_MARKER"; do
  as_root grep -q "$marker" "${logs[0]}" || { echo "Stage log missing marker: $marker" >&2; exit 1; }
done

if run_installer FAIL_STAGE=1 >"$tmp/failure.out" 2>&1; then
  echo "Failing child stage unexpectedly returned success" >&2
  exit 1
fi
mapfile -t logs < <(as_root find "$log_dir" -maxdepth 1 -type f -name 'run-*.log' | sort)
[[ "${#logs[@]}" -eq 2 ]] || { echo "Expected two stage logs, found ${#logs[@]}" >&2; exit 1; }
as_root grep -q "MODULE_FAILURE_MARKER" "${logs[@]}" || {
  echo "Failure output was not captured in the stage log" >&2
  exit 1
}

echo "Installer stage logging and exit-code propagation tests passed."
