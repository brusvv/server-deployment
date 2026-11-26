#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-}"
CONFIG_FILE="/opt/remnawave/nginx.conf"
CONTAINER="remnawave-nginx"

usage() {
  echo "Usage: $0 --check|--apply [--config FILE] [--container NAME]"
}

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "INFO: $*"; }

[[ "$ACTION" == "--check" || "$ACTION" == "--apply" ]] || { usage >&2; exit 2; }
shift
while (($#)); do
  case "$1" in
    --config) shift; (($#)) || die "--config needs a path"; CONFIG_FILE="$1" ;;
    --container) shift; (($#)) || die "--container needs a name"; CONTAINER="$1" ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done

[[ -f "$CONFIG_FILE" && ! -L "$CONFIG_FILE" ]] || die "Expected a regular, non-symlink Nginx config: $CONFIG_FILE"
command -v docker >/dev/null 2>&1 || die "Docker CLI is required."
docker ps --format '{{.Names}}' | grep -Fxq "$CONTAINER" || die "Nginx container '$CONTAINER' is not running."

# Determine whether the directive is already set at the snippet's top level.
# Nested server-level overrides are not a substitute for the global http-context setting.
read -r top_level_count invalid_count < <(python3 - "$CONFIG_FILE" <<'PY'
import re
import sys
from pathlib import Path

depth = 0
top_level = 0
invalid = 0
for raw in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    line = raw
    quote = None
    escaped = False
    clean = []
    for char in line:
        if escaped:
            clean.append(char)
            escaped = False
            continue
        if char == "\\" and quote:
            clean.append(char)
            escaped = True
            continue
        if quote:
            clean.append(char)
            if char == quote:
                quote = None
            continue
        if char in ("'", '"'):
            quote = char
            clean.append(char)
            continue
        if char == "#":
            break
        clean.append(char)
    statement = "".join(clean)
    match = re.match(r"^\\s*server_tokens\\s+(\\S+)\\s*;", statement)
    if match:
        if match.group(1) != "off":
            invalid += 1
        if depth == 0:
            top_level += 1
    # Count braces outside quoted strings/comments to track Nginx context.
    quote = None
    escaped = False
    for char in statement:
        if escaped:
            escaped = False
            continue
        if char == "\\" and quote:
            escaped = True
            continue
        if quote:
            if char == quote:
                quote = None
            continue
        if char in ("'", '"'):
            quote = char
        elif char == "{":
            depth += 1
        elif char == "}":
            depth = max(0, depth - 1)
print(top_level, invalid)
PY
)
if (( invalid > 0 )); then
  die "A non-off server_tokens directive exists in $CONFIG_FILE; review the config manually."
fi
if (( top_level > 1 )); then
  die "Multiple top-level server_tokens directives found in $CONFIG_FILE; refusing an ambiguous edit."
fi
if (( top_level == 1 )); then
  configured=1
else
  configured=0
fi

if [[ "$ACTION" == "--check" ]]; then
  (( configured == 1 )) || die "server_tokens off; is missing from $CONFIG_FILE."
  docker exec "$CONTAINER" nginx -t
  info "server_tokens off; is present and Nginx configuration is valid."
  exit 0
fi

if (( configured == 1 )); then
  docker exec "$CONTAINER" nginx -t
  info "server_tokens off; is already present; no file change or reload was needed."
  exit 0
fi

backup="${CONFIG_FILE}.before-server-deployment.$(date -u +%Y%m%dT%H%M%SZ).${BASHPID}"
tmp="$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")"
cleanup() { [[ -z "${tmp:-}" ]] || rm -f -- "$tmp"; }
trap cleanup EXIT
cp -a -- "$CONFIG_FILE" "$backup"
{
  printf '%s\n' 'server_tokens off;'
  cat -- "$CONFIG_FILE"
} > "$tmp"
chmod --reference="$CONFIG_FILE" "$tmp"
mv -f -- "$tmp" "$CONFIG_FILE"
tmp=""

if ! docker exec "$CONTAINER" nginx -t; then
  cp -a -- "$backup" "$CONFIG_FILE"
  docker exec "$CONTAINER" nginx -t || true
  die "Nginx validation failed; original config restored from $backup."
fi

if ! docker exec "$CONTAINER" nginx -s reload; then
  cp -a -- "$backup" "$CONFIG_FILE"
  docker exec "$CONTAINER" nginx -t || true
  docker exec "$CONTAINER" nginx -s reload || true
  die "Nginx reload failed; original config restored from $backup."
fi

info "Applied server_tokens off; backup: $backup"
