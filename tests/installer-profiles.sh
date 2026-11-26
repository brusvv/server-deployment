#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

source "$ROOT/profiles/remnawave-standard/profile.sh"
[[ "$PROFILE_ID" == "remnawave-standard" ]]
[[ "${PROFILE_STAGES[*]}" == "preflight backup system remnawave validate" ]]
# The standard profile must stay free of optional components and adapters.
[[ ! " ${PROFILE_STAGES[*]} " =~ " mtproxyl " ]]
[[ ! " ${PROFILE_STAGES[*]} " =~ " haproxy " ]]
[[ ! " ${PROFILE_STAGES[*]} " =~ " warp-masque " ]]
[[ ! " ${PROFILE_STAGES[*]} " =~ " adapter " ]]

source "$ROOT/profiles/remnawave-extended/profile.sh"
[[ "$PROFILE_ID" == "remnawave-extended" ]]
[[ "${PROFILE_STAGES[*]}" == "preflight backup system remnawave adapter mtproxyl haproxy validate warp-masque" ]]

source "$ROOT/profiles/remnawave-cascade/entry.sh"
[[ "$PROFILE_ID" == "remnawave-cascade-entry" ]]
[[ "${PROFILE_STAGES[*]}" == "preflight backup system validate" ]]

source "$ROOT/profiles/remnawave-cascade/exit-panel.sh"
[[ "$PROFILE_ID" == "remnawave-cascade-exit-panel" ]]
[[ "${PROFILE_STAGES[*]}" == "preflight backup system remnawave adapter mtproxyl haproxy validate warp-masque" ]]

printf 'Installer profile tests passed.\n'
