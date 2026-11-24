#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
config="$tmp/ports.env"
module="$tmp/server_routing.sh"

cat > "$config" <<'EOF'
SS_BRIDGE_ENABLED="0"
SS_BRIDGE_PORT="24443"
EOF

cat > "$module" <<'EOF'
SR_DEFAULT_PORT=9999

sr_setup() {
    local panel_ip="" host_ip="" host="" ss_port
    if [ -n "$panel_ip" ] && { [ "$host" = "$panel_ip" ] || [ "$host_ip" = "$panel_ip" ]; }; then
        if ! sr_find_node_by_host "$host" \
           || [ "$SR_NODE_CONNECTED" != "true" ] \
           || [ -z "$SR_NODE_UUID" ] \
           || [ -z "$SR_NODE_PROFILE" ]; then
            echo "same-box rejected"
            return 1
        fi
        echo "Reusing the existing connected local Node."
    fi
    sr_ask_port || return 1
    ss_port="$SR_ASKED_PORT"
    SR_TEST_PORT="$ss_port"
}

sr_state_get() {
    case "$1" in
        host) printf '%s' "exit.example" ;;
        port) printf '%s' "$TEST_STATE_PORT" ;;
        route_mode) printf '%s' "direct" ;;
        ss_password) printf '%s' "test-secret" ;;
        profile_uuid) printf '%s' "profile-uuid" ;;
        ru_profiles) printf '%s' "profile-uuid" ;;
        *) return 1 ;;
    esac
}

sr_attach_profile() {
    local host port mode password profile_uuid ru_list
    host="$(sr_state_get host)"
    port="$(sr_state_get port)"
    mode="$(sr_state_get route_mode)"
    password="$(sr_state_get ss_password)"
    profile_uuid="$(sr_state_get profile_uuid)"
    if [ -z "$host" ] || [ -z "$port" ] || [ -z "$password" ]; then
        echo -e "${COLOR_RED}${LANG[SR_ATTACH_NOT_READY]}${COLOR_RESET}"
        return 1
    fi

    ru_list="$(sr_state_get ru_profiles)"
    SR_TEST_ATTACH="1"
}

sr_teardown() {
    SR_TEST_TEARDOWN="1"
}

sr_ask_port() {
    SR_ASKED_PORT="$SR_DEFAULT_PORT"
}
EOF

before="$(sha256sum "$module" | awk '{print $1}')"
python3 "$ROOT/checks/egamesapi-bridge-integration.py" --check --config-file "$config" "$module" >/dev/null
after="$(sha256sum "$module" | awk '{print $1}')"
[[ "$before" == "$after" ]]

printf 'APPLY\n' | python3 "$ROOT/checks/egamesapi-bridge-integration.py" --apply --config-file "$config" "$module" >/dev/null
bash -n "$module"
grep -Fq 'SERVER_DEPLOYMENT_MANAGED_BRIDGE_SETUP_GUARD' "$module"
grep -Fq 'SERVER_DEPLOYMENT_MANAGED_BRIDGE_ATTACH_GUARD' "$module"
grep -Fq 'SERVER_DEPLOYMENT_MANAGED_BRIDGE_PORT_CHECK' "$module"

# Disabled means no new setup or profile attachment. Teardown remains callable.
(
    source "$module"
    if sr_setup; then
        echo "Disabled bridge unexpectedly allowed setup" >&2
        exit 1
    fi
    if sr_attach_profile; then
        echo "Disabled bridge unexpectedly allowed profile attachment" >&2
        exit 1
    fi
    sr_teardown
    [[ "$SR_TEST_TEARDOWN" == "1" ]]
)

# Enabling the bridge makes its configured port the only accepted port.
cat > "$config" <<'EOF'
SS_BRIDGE_ENABLED="1"
SS_BRIDGE_PORT="24443"
EOF
(
    source "$module"
    TEST_STATE_PORT="24443"
    sr_setup
    [[ "$SR_DEFAULT_PORT" == "24443" ]]
    [[ "$SR_TEST_PORT" == "24443" ]]
    sr_attach_profile
    [[ "$SR_TEST_ATTACH" == "1" ]]
)

# A manual port override is rejected so inbound/outbound/firewall cannot drift.
(
    source "$module"
    sr_ask_port() { SR_ASKED_PORT="9999"; }
    if sr_setup; then
        echo "Mismatched setup port unexpectedly passed" >&2
        exit 1
    fi
    TEST_STATE_PORT="9999"
    if sr_attach_profile; then
        echo "Mismatched saved attach port unexpectedly passed" >&2
        exit 1
    fi
)

# Reserved eGamesAPI node-control port is rejected.
cat > "$config" <<'EOF'
SS_BRIDGE_ENABLED="1"
SS_BRIDGE_PORT="2222"
EOF
if python3 "$ROOT/checks/egamesapi-bridge-integration.py" --check --config-file "$config" "$module" >/dev/null 2>&1; then
    echo "Reserved node-control port unexpectedly passed" >&2
    exit 1
fi

echo "eGamesAPI managed bridge integration tests passed."
