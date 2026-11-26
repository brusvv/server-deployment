#!/usr/bin/env bash
# shellcheck disable=SC2034
# VPS B hosts the Panel and local Exit Node, plus the separate MTProxy stack.
# shellcheck disable=SC2034
PROFILE_ID="remnawave-cascade-exit-panel"
# shellcheck disable=SC2034
PROFILE_TITLE="Каскад Remnawave — VPS B / Panel + Exit"
# shellcheck disable=SC2034
PROFILE_DESCRIPTION="Роль зарубежного сервера с Panel и локальным Exit Node. eGamesAPI и MTProxyL запускаются только через проверенные локальные установщики; HAProxy адаптирует существующую конфигурацию. Живой A→B bridge автоматически не создаётся."
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
