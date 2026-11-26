#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

seed="$tmp/seed"
origin="$tmp/origin.git"
install_dir="$tmp/install"
bootstrap_script="$tmp/bootstrap.sh"
cp "$ROOT/install.sh" "$bootstrap_script"
mkdir -p "$seed/lib"
cp "$ROOT/install.sh" "$seed/install.sh"
cp "$ROOT/lib/common.sh" "$ROOT/lib/config.sh" "$seed/lib/"
printf 'v1\n' > "$seed/VERSION.txt"
git -C "$seed" init --quiet -b bootstrap-test
git -C "$seed" config user.name "Bootstrap Test"
git -C "$seed" config user.email "bootstrap-test@example.invalid"
git -C "$seed" add .
git -C "$seed" commit --quiet -m "initial bootstrap fixture"
git init --quiet --bare "$origin"
git -C "$seed" remote add origin "file://$origin"
git -C "$seed" push --quiet -u origin bootstrap-test

run_bootstrap() {
  SD_REPO_URL="file://$origin" SD_GIT_REF=bootstrap-test SD_INSTALL_DIR="$install_dir" \
    bash "$bootstrap_script" --help
}

run_bootstrap >/dev/null
[[ "$(cat "$install_dir/VERSION.txt")" == "v1" ]] || { echo "Initial bootstrap clone failed" >&2; exit 1; }

printf 'v2\n' > "$seed/VERSION.txt"
git -C "$seed" add VERSION.txt
git -C "$seed" commit --quiet -m "update bootstrap fixture"
git -C "$seed" push --quiet origin bootstrap-test

run_bootstrap >/dev/null
[[ "$(cat "$install_dir/VERSION.txt")" == "v2" ]] || { echo "Clean checkout was not fast-forwarded" >&2; exit 1; }

printf 'local edit\n' >> "$install_dir/VERSION.txt"
if run_bootstrap >"$tmp/dirty.out" 2>&1; then
  echo "Bootstrap unexpectedly accepted a dirty checkout" >&2
  exit 1
fi
grep -q "local modifications or untracked files" "$tmp/dirty.out" || {
  echo "Dirty checkout refusal message missing" >&2
  exit 1
}
grep -q "local edit" "$install_dir/VERSION.txt" || {
  echo "Bootstrap changed local modifications" >&2
  exit 1
}

echo "Bootstrap refresh tests passed."
