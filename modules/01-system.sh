#!/usr/bin/env bash
set -Eeuo pipefail
source "$SD_ROOT/lib/common.sh"
require_root
confirm "Install base packages and create state directories?" || exit 0
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl git jq openssl socat iproute2 dnsutils gettext-base
install -d -m 0700 "$STATE_DIR" "$BACKUP_DIR"
install -d -m 0750 /var/log/server-deployment
