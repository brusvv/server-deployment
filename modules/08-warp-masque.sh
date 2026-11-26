#!/usr/bin/env bash
set -Eeuo pipefail
source "$SD_ROOT/lib/common.sh"
require_root
if [[ "$SD_MODE" == check || "$SD_DRY_RUN" == 1 ]]; then
  python3 "$SD_ROOT/lib/warp_masque.py" status
  info "WARP MASQUE check-only: no registration or Panel config was changed."
  exit 0
fi
python3 "$SD_ROOT/lib/warp_masque.py" initial
