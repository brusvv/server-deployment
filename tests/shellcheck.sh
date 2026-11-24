#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
if command -v shellcheck >/dev/null 2>&1; then
 find . -type f -name '*.sh' -print0 | xargs -0 shellcheck
else
 echo "ShellCheck not installed; running bash -n only"
fi
find . -type f -name '*.sh' -print0 | while IFS= read -r -d '' file; do bash -n "$file"; done
python3 -m py_compile lib/haproxy_config.py checks/egamesapi-local-exit-compat.py checks/egamesapi-bridge-integration.py
bash tests/port-discovery.sh
bash tests/egamesapi-local-exit-compat.sh
bash tests/egamesapi-bridge-integration.sh
bash tests/cascade-config.sh
echo "Static shell and HAProxy port checks passed."
