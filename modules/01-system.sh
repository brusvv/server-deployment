#!/usr/bin/env bash
set -Eeuo pipefail
source "$SD_ROOT/lib/common.sh"
require_root

confirm "Install required base packages and create state directories?" ||
  die "Required system preparation was declined; the profile cannot continue."

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl git jq openssl socat iproute2 dnsutils gettext-base python3
install -d -m 0700 "$STATE_DIR" "$BACKUP_DIR"
install -d -m 0750 /var/log/server-deployment
info "Required system preparation completed."
