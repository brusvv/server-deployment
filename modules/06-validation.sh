#!/usr/bin/env bash
set -Eeuo pipefail
source "$SD_ROOT/lib/common.sh"
"$SD_ROOT/checks/domains.sh"
"$SD_ROOT/checks/ports.sh"
"$SD_ROOT/checks/services.sh"
info "Validation completed; review warnings for components not installed yet."
