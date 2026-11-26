#!/usr/bin/env bash
set -Eeuo pipefail
source "$SD_ROOT/lib/common.sh"
require_root

# Pin eGamesAPI to a reviewed upstream commit. The complete checkout is used
# so its bundled src/ modules are loaded locally instead of tracking main.
readonly EGAMES_REPO="https://github.com/eGamesAPI/remnawave-reverse-proxy.git"
readonly EGAMES_COMMIT="93e6631aae5f7bff28eadfc45faab43150cc22c6"
readonly EGAMES_VERSION="3.8.4"

cat <<'EOF'
eGamesAPI Remnawave Reverse-Proxy will be launched from a pinned source commit.
For this single-host profile, select:
  1. Install Remnawave Components
  1. Install panel and node on one server

IMPORTANT: eGamesAPI documents the combined Panel + Node mode as not recommended
for production. It recommends separate Panel-only / Node-only deployment modes.
EOF

confirm "I understand the single-server Panel + Node limitation; continue with eGamesAPI?" ||
  die "eGamesAPI installation was not confirmed."

have git || die "git is required to retrieve the pinned eGamesAPI source."

work_dir="$(mktemp -d /tmp/egamesapi-installer.XXXXXX)"
cleanup() { rm -rf -- "$work_dir"; }
trap cleanup EXIT

git -C "$work_dir" init -q
git -C "$work_dir" remote add origin "$EGAMES_REPO"
git -C "$work_dir" fetch --quiet --depth 1 origin "$EGAMES_COMMIT" ||
  die "Could not fetch pinned eGamesAPI commit $EGAMES_COMMIT."
git -C "$work_dir" checkout --quiet --detach FETCH_HEAD
actual_commit="$(git -C "$work_dir" rev-parse HEAD)"
[[ "$actual_commit" == "$EGAMES_COMMIT" ]] ||
  die "eGamesAPI source commit mismatch: expected $EGAMES_COMMIT, got $actual_commit."

installer="$work_dir/install_remnawave.sh"
[[ -s "$installer" && -d "$work_dir/src" ]] ||
  die "Pinned eGamesAPI checkout is missing the installer or bundled src directory."
grep -Fq "SCRIPT_VERSION=\"$EGAMES_VERSION\"" "$installer" ||
  die "Pinned eGamesAPI installer version does not match expected $EGAMES_VERSION."
head -n 1 "$installer" | grep -q '^#!/bin/bash$' ||
  die "Downloaded eGamesAPI installer has an unexpected file header."
bash -n "$installer" || die "Pinned eGamesAPI installer failed bash syntax validation."

info "Launching eGamesAPI $EGAMES_VERSION ($EGAMES_COMMIT)."
info "Choose menu item 1, then item 1 (Panel + Node on one server)."
bash "$installer"

have docker || die "eGamesAPI returned without making the Docker CLI available."
docker ps --format '{{.Names}}' > "$work_dir/running-containers"
grep -qxE 'remnawave(-db)?' "$work_dir/running-containers" ||
  die "eGamesAPI returned success, but the Remnawave Panel container is not running."
grep -qx 'remnanode' "$work_dir/running-containers" ||
  die "eGamesAPI returned success, but the local Remnawave Node container is not running."

info "Verified running containers: Remnawave Panel and local Remnawave Node."

# Harden the generated Nginx response before declaring the eGamesAPI stage complete.
# The helper backs up the host config, validates it inside the container and reloads
# only remnawave-nginx; it is idempotent and restores the backup on failure.
bash "$SD_ROOT/checks/remnawave-nginx-hardening.sh" --apply
