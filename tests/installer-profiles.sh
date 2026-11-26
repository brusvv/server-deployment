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
[[ "${PROFILE_OPTIONAL_STAGES[*]}" == "mtproxyl haproxy warp-masque" ]]

source "$ROOT/profiles/remnawave-cascade/entry.sh"
[[ "$PROFILE_ID" == "remnawave-cascade-entry" ]]
[[ "${PROFILE_STAGES[*]}" == "preflight backup system validate" ]]

source "$ROOT/profiles/remnawave-cascade/exit-panel.sh"
[[ "$PROFILE_ID" == "remnawave-cascade-exit-panel" ]]
[[ "${PROFILE_STAGES[*]}" == "preflight backup system remnawave adapter mtproxyl haproxy validate warp-masque" ]]
[[ "${PROFILE_OPTIONAL_STAGES[*]}" == "mtproxyl haproxy warp-masque" ]]

# Mandatory stages must fail closed on an explicit decline; eGamesAPI is pinned.
grep -q 'die "Required system preparation was declined' "$ROOT/modules/01-system.sh"
grep -q 'die "eGamesAPI installation was not confirmed' "$ROOT/modules/02-remnawave.sh"
grep -q 'EGAMES_COMMIT="93e6631aae5f7bff28eadfc45faab43150cc22c6"' "$ROOT/modules/02-remnawave.sh"
grep -q 'exit 10' "$ROOT/modules/04-mtproxyl.sh"
grep -q 'PROFILE_OPTIONAL_STAGES' "$ROOT/installer/main.sh"
grep -q 'XRAY_LISTENER_REQUIRED="1"' "$ROOT/config/services.env"
grep -q 'check_backend_listener "Xray"' "$ROOT/modules/05-haproxy.sh"
grep -q 'exit 10' "$ROOT/modules/05-haproxy.sh"
grep -q 'Configure the selected Remnawave Config Profile' "$ROOT/modules/03-network-adapter.sh"

printf 'Installer profile tests passed.\n'
