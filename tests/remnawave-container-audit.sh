#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat > "$tmp/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -Eeuo pipefail
required=(remnawave-db remnawave-redis remnawave remnawave-nginx remnawave-subscription-page remnanode)
case "$1" in
  ps)
    for name in "${required[@]}"; do
      [[ "${FAKE_DOCKER_MISSING:-}" == "$name" ]] || printf '%s\n' "$name"
    done
    ;;
  inspect)
    format="$3"
    container="$4"
    case "$format" in
      '{{.State.Status}}') echo running ;;
      '{{.Config.Image}}') echo "example/$container:latest" ;;
      '{{.Image}}') echo "sha256:fake-$container" ;;
      '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')
        if [[ "${FAKE_DOCKER_UNHEALTHY:-}" == "$container" ]]; then
          echo unhealthy
        elif [[ "${FAKE_DOCKER_STARTING_ONCE:-}" == "$container" && ! -e "${FAKE_DOCKER_STATE_FILE:-}" ]]; then
          : > "$FAKE_DOCKER_STATE_FILE"
          echo starting
        else
          echo healthy
        fi
        ;;
      *) echo "Unexpected docker inspect template: $format" >&2; exit 2 ;;
    esac
    ;;
  image)
    [[ "$2" == inspect ]] || exit 2
    echo "example/$5@sha256:repo-digest"
    ;;
  *)
    echo "Unexpected docker command: $*" >&2
    exit 2
    ;;
esac
DOCKER
cat > "$tmp/bin/sleep" <<'SLEEP'
#!/usr/bin/env bash
exit 0
SLEEP
chmod +x "$tmp/bin/docker" "$tmp/bin/sleep"

PATH="$tmp/bin:$PATH" bash "$ROOT/checks/remnawave-container-audit.sh" >"$tmp/success.out"
grep -q "All expected eGamesAPI Panel + Node containers are running" "$tmp/success.out"
grep -q "repo_digests=example/" "$tmp/success.out"

PATH="$tmp/bin:$PATH" FAKE_DOCKER_STARTING_ONCE=remnawave FAKE_DOCKER_STATE_FILE="$tmp/starting.once" \
  bash "$ROOT/checks/remnawave-container-audit.sh" >"$tmp/starting.out"
grep -q "Container health is healthy: remnawave" "$tmp/starting.out" || {
  echo "Container audit did not wait through the starting health state" >&2
  exit 1
}

if PATH="$tmp/bin:$PATH" FAKE_DOCKER_MISSING=remnawave-nginx \
  bash "$ROOT/checks/remnawave-container-audit.sh" >"$tmp/missing.out" 2>&1; then
  echo "Missing Nginx container unexpectedly passed" >&2
  exit 1
fi
grep -q "Required eGamesAPI container is not running: remnawave-nginx" "$tmp/missing.out"

if PATH="$tmp/bin:$PATH" FAKE_DOCKER_UNHEALTHY=remnawave-redis \
  bash "$ROOT/checks/remnawave-container-audit.sh" >"$tmp/unhealthy.out" 2>&1; then
  echo "Unhealthy Redis container unexpectedly passed" >&2
  exit 1
fi
grep -q "Container remnawave-redis is not healthy" "$tmp/unhealthy.out"

echo "Remnawave container health and image audit tests passed."
