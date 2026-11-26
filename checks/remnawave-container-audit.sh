#!/usr/bin/env bash
# Read-only post-install audit of the pinned eGamesAPI Panel + Node topology.
set -Eeuo pipefail

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf 'INFO: %s\n' "$*"; }

command -v docker >/dev/null 2>&1 || die "Docker CLI is unavailable."
running="$(docker ps --format '{{.Names}}')" || die "Cannot query running Docker containers."

required_containers=(
  remnawave-db
  remnawave-redis
  remnawave
  remnawave-nginx
  remnawave-subscription-page
  remnanode
)
for container in "${required_containers[@]}"; do
  grep -Fxq -- "$container" <<< "$running" || die "Required eGamesAPI container is not running: $container"
  state="$(docker inspect --format '{{.State.Status}}' "$container")" || die "Cannot inspect container state: $container"
  [[ "$state" == "running" ]] || die "Container $container is not running (state: $state)."

  image_ref="$(docker inspect --format '{{.Config.Image}}' "$container")" || die "Cannot inspect image reference: $container"
  image_id="$(docker inspect --format '{{.Image}}' "$container")" || die "Cannot inspect image ID: $container"
  repo_digests="$(docker image inspect --format '{{join .RepoDigests ","}}' "$image_id" 2>/dev/null || true)"
  info "Container image: $container ref=$image_ref image_id=$image_id repo_digests=${repo_digests:-unavailable}"
done

wait_for_healthy() {
  local container="$1" attempt health
  for attempt in {1..40}; do
    health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container")" ||
      die "Cannot inspect health status: $container"
    case "$health" in
      healthy)
        info "Container health is healthy: $container"
        return 0
        ;;
      unhealthy)
        die "Container $container reported unhealthy."
        ;;
      starting)
        sleep 3
        ;;
      *)
        die "Container $container has no usable health check (health: $health)."
        ;;
    esac
  done
  die "Container $container did not become healthy within 120 seconds (last status: $health)."
}

for container in remnawave-db remnawave-redis remnawave; do
  wait_for_healthy "$container"
done

info "All expected eGamesAPI Panel + Node containers are running; database, cache and Panel health checks are healthy."
info "Image references and immutable local image IDs/digests were recorded for this installation."
