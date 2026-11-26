#!/usr/bin/env bash
# Current single-host orchestration sequence.
PROFILE_ID="single-server"
PROFILE_TITLE="Один сервер"
PROFILE_DESCRIPTION="Развёртывание компонентов на одной VPS. HAProxy адаптирует уже установленную конфигурацию MTProxyL, а не устанавливается самостоятельно."
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
