#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
config="$tmp/ports.env"
module="$tmp/server_routing.sh"

cat > "$config" <<'EOF'
SS_BRIDGE_ENABLED="1"
SS_BRIDGE_PORT="24443"
EOF

cat > "$module" <<'EOF'
SR_DEFAULT_PORT=9999

sr_setup() {
    local host ss_port
    local panel_ip host_ip
    panel_ip="203.0.113.20"
    host="203.0.113.20"
    host_ip="203.0.113.20"
    if [ -n "$panel_ip" ] && { [ "$host" = "$panel_ip" ] || [ "$host_ip" = "$panel_ip" ]; }; then
        echo -e "${COLOR_RED}${LANG[SR_SAME_BOX]}${COLOR_RESET}"
        return 1
    fi
    sr_ask_port || return 1
    ss_port="$SR_ASKED_PORT"
    sr_pick_route_mode || { echo -e "${COLOR_YELLOW}${LANG[RE_CANCELLED]}${COLOR_RESET}"; return 1; }
}

sr_pick_route_mode() {
    SR_ROUTE_MODE="bridge"
}

sr_attach_profile() {
    local host port mode password profile_uuid ru_list
    host=$(sr_state_get host)
    port=$(sr_state_get port)
    mode=$(sr_state_get route_mode)
    password=$(sr_state_get ss_password)
    profile_uuid=$(sr_state_get profile_uuid)
    if [ -z "$host" ] || [ -z "$port" ] || [ -z "$password" ]; then
        echo -e "${COLOR_RED}${LANG[SR_ATTACH_NOT_READY]}${COLOR_RESET}"
        return 1
    fi

    ru_list=$(sr_state_get ru_profiles)
}

sr_ask_port() {
    SR_ASKED_PORT="$SR_DEFAULT_PORT"
}
EOF

before="$(sha256sum "$module" | awk '{print $1}')"
cp -p "$module" "$tmp/original-server-routing.sh"
bash "$ROOT/checks/egamesapi-bridge-adapters.sh" --check --config-file "$config" --module "$module" >/dev/null
after="$(sha256sum "$module" | awk '{print $1}')"
[[ "$before" == "$after" ]]

printf 'APPLY\n' | bash "$ROOT/checks/egamesapi-bridge-adapters.sh" --apply --config-file "$config" --module "$module" >/dev/null
bash -n "$module"
grep -Fq 'SERVER_DEPLOYMENT_MANAGED_GEO_DIRECT_MODE' "$module"
grep -Fq 'SERVER_DEPLOYMENT_MANAGED_BRIDGE_SETUP_GUARD' "$module"
grep -Fq 'SERVER_DEPLOYMENT_MANAGED_BRIDGE_ATTACH_GUARD' "$module"
grep -Fq 'SERVER_DEPLOYMENT_MANAGED_BRIDGE_PORT_CHECK' "$module"
grep -Fq 'SERVER_DEPLOYMENT_MANAGED_BRIDGE_ATTACH_PORT_CHECK' "$module"
grep -Fq 'SERVER_DEPLOYMENT_MANAGED_BRIDGE_ATTACH_MODE_CHECK' "$module"

backup_count="$(find "$tmp" -maxdepth 1 -name 'server_routing.sh.before-server-deployment.*' -type f | wc -l)"
[[ "$backup_count" -ge 2 ]]

bash "$ROOT/checks/egamesapi-bridge-adapters.sh" --check --config-file "$config" --module "$module" >/dev/null

# Inject a failure in the second real apply operation. The combined runner must
# restore the exact pre-transaction module rather than leave patch one behind.
failure_dir="$tmp/failure"
fake_bin="$tmp/fake-bin"
mkdir -p "$failure_dir" "$fake_bin"
failure_module="$failure_dir/server_routing.sh"
cp -p "$tmp/original-server-routing.sh" "$failure_module"
real_python3="$(command -v python3)"
cat > "$fake_bin/python3" <<'PY'
#!/usr/bin/env bash
if [[ "$1" == "$SD_BRIDGE_PATCH" ]]; then
  for arg in "$@"; do
    [[ "$arg" == "--apply" ]] && { echo "Injected bridge patch failure" >&2; exit 42; }
  done
fi
exec "$REAL_PYTHON3" "$@"
PY
chmod +x "$fake_bin/python3"
failure_before="$(sha256sum "$failure_module" | awk '{print $1}')"
if printf 'APPLY\n' | env PATH="$fake_bin:$PATH" REAL_PYTHON3="$real_python3" \
  SD_BRIDGE_PATCH="$ROOT/checks/egamesapi-bridge-integration.py" \
  bash "$ROOT/checks/egamesapi-bridge-adapters.sh" --apply --config-file "$config" --module "$failure_module" \
  >"$tmp/rollback.out" 2>&1; then
  echo "Injected second-patch failure unexpectedly succeeded" >&2
  exit 1
fi
failure_after="$(sha256sum "$failure_module" | awk '{print $1}')"
[[ "$failure_before" == "$failure_after" ]] || {
  echo "Combined adapter runner did not restore the original module after second-patch failure" >&2
  cat "$tmp/rollback.out" >&2
  exit 1
}
grep -q "ROLLBACK: original eGamesAPI module restored" "$tmp/rollback.out" || {
  echo "Rollback confirmation was not reported" >&2
  cat "$tmp/rollback.out" >&2
  exit 1
}

echo "Combined eGamesAPI bridge adapter runner tests passed."
