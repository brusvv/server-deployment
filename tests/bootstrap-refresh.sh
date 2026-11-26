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

run_bootstrap_at() {
  local destination="$1"
  SD_REPO_URL="file://$origin" SD_GIT_REF=bootstrap-test SD_INSTALL_DIR="$destination" \
    bash "$bootstrap_script" --help
}
run_bootstrap() { run_bootstrap_at "$install_dir"; }

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

# A checkout on another branch must be rejected without switching branches.
install_mismatch="$tmp/install-mismatch"
run_bootstrap_at "$install_mismatch" >/dev/null
git -C "$install_mismatch" checkout --quiet -b wrong-branch
if run_bootstrap_at "$install_mismatch" >"$tmp/mismatch.out" 2>&1; then
  echo "Bootstrap unexpectedly switched a mismatched branch" >&2
  exit 1
fi
grep -q "is on 'wrong-branch', but SD_GIT_REF requests 'bootstrap-test'" "$tmp/mismatch.out"
[[ "$(git -C "$install_mismatch" branch --show-current)" == "wrong-branch" ]]

# A local commit that diverges from the requested remote branch must be kept
# untouched and reported, not reset or merged automatically.
install_diverged="$tmp/install-diverged"
run_bootstrap_at "$install_diverged" >/dev/null
git -C "$install_diverged" config user.name "Bootstrap Test"
git -C "$install_diverged" config user.email "bootstrap-test@example.invalid"
printf 'local divergent commit\n' > "$install_diverged/VERSION.txt"
git -C "$install_diverged" add VERSION.txt
git -C "$install_diverged" commit --quiet -m "local divergent change"

printf 'v3\n' > "$seed/VERSION.txt"
git -C "$seed" add VERSION.txt
git -C "$seed" commit --quiet -m "remote divergent change"
git -C "$seed" push --quiet origin bootstrap-test

if run_bootstrap_at "$install_diverged" >"$tmp/diverged.out" 2>&1; then
  echo "Bootstrap unexpectedly reconciled divergent histories" >&2
  exit 1
fi
grep -q "local checkout and remote bootstrap-test have diverged" "$tmp/diverged.out"
grep -q "local divergent commit" "$install_diverged/VERSION.txt" || {
  echo "Bootstrap modified the local divergent commit" >&2
  exit 1
}

echo "Bootstrap refresh tests passed."
