#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/no-ss-bin"
cat > "$tmp/bin/ss" <<'SS'
#!/usr/bin/env bash
# Empty listener inventory for deterministic preflight tests.
exit 0
SS
chmod +x "$tmp/bin/ss"
ln -s "$(command -v date)" "$tmp/no-ss-bin/date"

run_ports() {
  env PATH="$tmp/bin:$PATH" SD_ROOT="$ROOT" \
    PUBLIC_HTTP_PORT="${1:-80}" PUBLIC_HTTPS_PORT="${2:-443}" \
    SS_BRIDGE_ENABLED="${3:-0}" SS_BRIDGE_PORT="${4:-9999}" \
    bash "$ROOT/checks/ports.sh"
}

run_ports 80 443 0 9999 >/dev/null
run_ports 080 0443 0 9999 >/dev/null
run_ports 80 443 1 9999 >/dev/null

expect_failure() {
  local label="$1"; shift
  if run_ports "$@" >"$tmp/out" 2>&1; then
    echo "$label unexpectedly passed" >&2
    exit 1
  fi
}
expect_failure "Non-numeric public HTTP port" abc 443 0 9999
expect_failure "Out-of-range public HTTPS port" 80 65536 0 9999
expect_failure "Zero public HTTP port" 0 443 0 9999
expect_failure "Duplicate public ports" 443 443 0 9999
expect_failure "Bridge/public port collision" 80 443 1 443
expect_failure "Non-numeric bridge port" 80 443 1 abc

# Missing iproute2/ss must be an explicit preflight failure, never reported as
# an apparently free public port.
PATH="$tmp/no-ss-bin" SD_ROOT="$ROOT" PUBLIC_HTTP_PORT=80 PUBLIC_HTTPS_PORT=443 \
  /bin/bash "$ROOT/checks/ports.sh" >"$tmp/no-ss.out" 2>&1
grep -q "port occupancy checks are skipped, not assumed free" "$tmp/no-ss.out" || {
  echo "Missing ss warning not found" >&2
  exit 1
}
if PATH="$tmp/no-ss-bin" SD_ROOT="$ROOT" PUBLIC_HTTP_PORT=70000 PUBLIC_HTTPS_PORT=443 \
  /bin/bash "$ROOT/checks/ports.sh" >"$tmp/no-ss-invalid.out" 2>&1; then
  echo "Invalid public port unexpectedly passed without ss" >&2
  exit 1
fi
grep -q "outside the valid port range" "$tmp/no-ss-invalid.out" || {
  echo "Port validation was skipped when ss was missing" >&2
  exit 1
}

echo "Public and bridge port validation tests passed."
