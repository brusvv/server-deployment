#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin"
export DOCKER_LOG="$tmp/docker.log"

cat > "$tmp/bin/docker" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
if [[ "${1:-}" == "ps" ]]; then
  echo "remnawave-nginx"
  exit 0
fi
if [[ "${1:-}" == "exec" ]]; then
  exit 0
fi
exit 1
MOCK
chmod +x "$tmp/bin/docker"
export PATH="$tmp/bin:$PATH"

config="$tmp/nginx.conf"
cat > "$config" <<'CONF'
server {
    listen 8080;
}
CONF

bash checks/remnawave-nginx-hardening.sh --apply --config "$config"
grep -Fxq 'server_tokens off;' "$config"
backup_count="$(find "$tmp" -maxdepth 1 -name 'nginx.conf.before-server-deployment.*' | wc -l)"
[[ "$backup_count" -eq 1 ]]
bash checks/remnawave-nginx-hardening.sh --check --config "$config"
bash checks/remnawave-nginx-hardening.sh --apply --config "$config"
reload_count="$(grep -c 'nginx -s reload' "$DOCKER_LOG" || true)"
[[ "$reload_count" -eq 1 ]]

# A nested server-level directive does not satisfy the global http-context setting.
nested="$tmp/nginx-nested.conf"
printf 'server {\n    server_tokens off;\n}\n' > "$nested"
bash checks/remnawave-nginx-hardening.sh --apply --config "$nested"
[[ "$(head -n 1 "$nested")" == 'server_tokens off;' ]]
[[ "$(grep -c 'server_tokens off;' "$nested")" -eq 2 ]]
bash checks/remnawave-nginx-hardening.sh --check --config "$nested"

# Existing non-off directives and ambiguous duplicate directives must fail closed.
bad="$tmp/nginx-bad.conf"
printf 'server_tokens on;\n' > "$bad"
if bash checks/remnawave-nginx-hardening.sh --apply --config "$bad"; then
  echo "Expected non-off server_tokens directive to be rejected" >&2
  exit 1
fi
[[ "$(cat "$bad")" == 'server_tokens on;' ]]

duplicate="$tmp/nginx-duplicate.conf"
printf 'server_tokens off;\nserver_tokens off;\n' > "$duplicate"
if bash checks/remnawave-nginx-hardening.sh --apply --config "$duplicate"; then
  echo "Expected duplicate server_tokens directives to be rejected" >&2
  exit 1
fi

echo "Remnawave Nginx hardening checks passed."
