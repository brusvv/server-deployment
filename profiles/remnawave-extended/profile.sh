#!/usr/bin/env bash
# shellcheck disable=SC2034
# Extended single-host profile with optional proxy and routing integrations.
# shellcheck disable=SC2034
PROFILE_ID="remnawave-extended"
# shellcheck disable=SC2034
PROFILE_TITLE="Remnawave + дополнительные компоненты"
# shellcheck disable=SC2034
PROFILE_DESCRIPTION="Расширенное развёртывание через eGamesAPI: Panel + локальная Node, сетевой адаптер, MTProxyL, HAProxy и опциональный WARP/MASQUE. Upstream не рекомендует объединённый Panel + Node режим для production. HAProxy адаптирует существующую конфигурацию MTProxyL и требует Xray на loopback."
# shellcheck disable=SC2034
PROFILE_STAGES=(
  preflight
  backup
  system
  remnawave
  adapter
  mtproxyl
  haproxy
  validate
  warp-masque
)

# These components are optional; the core eGamesAPI Panel + Node stage is mandatory.
# shellcheck disable=SC2034
PROFILE_OPTIONAL_STAGES=(mtproxyl haproxy warp-masque)
