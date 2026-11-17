#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
if command -v shellcheck >/dev/null 2>&1; then
 find . -type f -name '*.sh' -print0 | xargs -0 shellcheck
else
 echo "ShellCheck not installed; running bash -n only"
fi
find . -type f -name '*.sh' -print0 | while IFS= read -r -d '' file; do bash -n "$file"; done
echo "Static shell checks passed."
