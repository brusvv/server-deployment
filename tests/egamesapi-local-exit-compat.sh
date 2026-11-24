#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
module="$tmp/server_routing.sh"
cat > "$module" <<'EOF'
#!/usr/bin/env bash
sr_setup() {
    local panel_ip host_ip
    panel_ip="$(sr_panel_public_ip)"
    host_ip="$(dig +short A "$host" 2>/dev/null)"
    if [ -n "$panel_ip" ] && { [ "$host" = "$panel_ip" ] || [ "$host_ip" = "$panel_ip" ]; }; then
        echo -e "${COLOR_RED}${LANG[SR_SAME_BOX]}${COLOR_RESET}"
        return 1
    fi
}
EOF
cp "$module" "$tmp/original.sh"

python3 "$ROOT/checks/egamesapi-local-exit-compat.py" --check "$module" >/dev/null
cmp -s "$tmp/original.sh" "$module"

printf 'APPLY\n' | python3 "$ROOT/checks/egamesapi-local-exit-compat.py" --apply "$module" >/dev/null
grep -Fq "sr_find_node_by_host \"\$host\"" "$module"
grep -Fq "[ \"\$SR_NODE_CONNECTED\" != \"true\" ]" "$module"
grep -Fq 'Reusing the existing connected local Node.' "$module"
bash -n "$module"

backup="$(find "$tmp" -maxdepth 1 -name 'server_routing.sh.before-server-deployment.*' -type f -print -quit)"
[[ -n "$backup" ]]
cmp -s "$tmp/original.sh" "$backup"

python3 "$ROOT/checks/egamesapi-local-exit-compat.py" --check "$module" >/dev/null
before_count="$(find "$tmp" -maxdepth 1 -name 'server_routing.sh.before-server-deployment.*' -type f | wc -l)"
cp "$module" "$tmp/patched-before-idempotency.sh"
printf 'APPLY\n' | python3 "$ROOT/checks/egamesapi-local-exit-compat.py" --apply "$module" >/dev/null
after_count="$(find "$tmp" -maxdepth 1 -name 'server_routing.sh.before-server-deployment.*' -type f | wc -l)"
[[ "$before_count" == "$after_count" ]]
cmp -s "$tmp/patched-before-idempotency.sh" "$module"
echo "eGamesAPI local Exit compatibility patch tests passed."
