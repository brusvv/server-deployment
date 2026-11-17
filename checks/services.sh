#!/usr/bin/env bash
set -Eeuo pipefail
source "$SD_ROOT/lib/common.sh"
for service in "$XRAY_SERVICE_HINT" "$HAPROXY_SERVICE"; do
 systemctl list-unit-files "$service" --no-legend 2>/dev/null | grep -q "$service" || { warn "$service not found"; continue; }
 systemctl is-active --quiet "$service" && info "$service active" || warn "$service installed but inactive"
done
