#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
fixture="$tmp/fixture"
mkdir -p "$fixture/lib"
cp "$ROOT/modules/04-mtproxyl.sh" "$fixture/mtproxyl.sh"
cat > "$fixture/lib/common.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
require_root(){ :; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
warn(){ :; }
info(){ :; }
err(){ printf 'ERROR: %s\n' "$*" >&2; }
confirm(){ return 1; }
EOF

valid="$tmp/valid-installer.sh"
printf '#!/usr/bin/env bash\necho should-not-run\n' > "$valid"
chmod 0700 "$valid"
invalid="$tmp/invalid-installer.sh"
printf '#!/usr/bin/env bash\nif then\n' > "$invalid"
symlink="$tmp/installer-link.sh"
ln -s "$valid" "$symlink"

expect_failure() {
  local label="$1" path="$2"
  if SD_ROOT="$fixture" MTPROXYL_INSTALLER_LOCAL="$path" bash "$fixture/mtproxyl.sh" >"$tmp/out" 2>&1; then
    echo "$label unexpectedly passed" >&2
    exit 1
  fi
}
expect_failure "Relative installer path" "relative-installer.sh"
expect_failure "Symlink installer" "$symlink"
expect_failure "Invalid Bash installer" "$invalid"

set +e
SD_ROOT="$fixture" MTPROXYL_INSTALLER_LOCAL="$valid" bash "$fixture/mtproxyl.sh" >"$tmp/valid.out" 2>&1
status=$?
set -e
[[ "$status" -eq 10 ]] || { echo "Valid but declined installer should return optional-skip 10, got $status" >&2; exit 1; }

echo "MTProxyL local installer guard tests passed."
