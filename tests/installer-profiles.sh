#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

source "$ROOT/profiles/single-server/profile.sh"
[[ "$PROFILE_ID" == "single-server" ]]
[[ "${PROFILE_STAGES[*]}" == "preflight backup system remnawave adapter mtproxyl haproxy validate warp-masque" ]]

source "$ROOT/profiles/remnawave-cascade/entry.sh"
[[ "$PROFILE_ID" == "remnawave-cascade-entry" ]]
[[ "${PROFILE_STAGES[*]}" == "preflight backup system validate" ]]

source "$ROOT/profiles/remnawave-cascade/exit-panel.sh"
[[ "$PROFILE_ID" == "remnawave-cascade-exit-panel" ]]
[[ "${PROFILE_STAGES[*]}" == "preflight backup system remnawave adapter mtproxyl haproxy validate warp-masque" ]]

printf 'Installer profile tests passed.\n'
