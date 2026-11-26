#!/usr/bin/env bash
# shellcheck disable=SC2034
# VPS B hosts the Panel and local Exit Node, plus the separate MTProxy stack.
PROFILE_ID="remnawave-cascade-exit-panel"
PROFILE_TITLE="Каскад Remnawave — VPS B / Panel + Exit"
PROFILE_DESCRIPTION="Роль зарубежного сервера с Panel и локальным Exit Node. eGamesAPI и MTProxyL запускаются только через проверенные локальные установщики; HAProxy адаптирует существующую конфигурацию. Живой A→B bridge автоматически не создаётся."
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
