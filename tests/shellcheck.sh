#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
if command -v shellcheck >/dev/null 2>&1; then
 find . -type f -name '*.sh' -print0 | xargs -0 shellcheck
else
 echo "ShellCheck not installed; running bash -n only"
fi
find . -type f -name '*.sh' -print0 | while IFS= read -r -d '' file; do bash -n "$file"; done
python3 -m py_compile lib/backup_archive.py lib/haproxy_config.py lib/warp_masque.py checks/egamesapi-local-exit-compat.py checks/egamesapi-bridge-integration.py tests/warp-masque.py
python3 -m py_compile checks/backup-archive-tests.py tests/installer-orchestration.py
python3 checks/backup-archive-tests.py
python3 tests/installer-orchestration.py
bash tests/port-discovery.sh
bash tests/egamesapi-local-exit-compat.sh
bash tests/egamesapi-bridge-integration.sh
bash tests/egamesapi-bridge-adapters.sh
bash tests/remnawave-nginx-hardening.sh
bash tests/common-logging.sh
bash tests/backup-dry-run.sh
bash tests/backup-restore-safety.sh
bash tests/bootstrap-refresh.sh
bash tests/cascade-config.sh
bash tests/installer-profiles.sh
python3 tests/warp-masque.py
echo "Static shell and HAProxy port checks passed."
