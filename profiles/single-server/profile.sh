#!/usr/bin/env bash
# shellcheck disable=SC2034
# Current single-host orchestration sequence.
# shellcheck disable=SC2034
PROFILE_ID="single-server"
# shellcheck disable=SC2034
PROFILE_TITLE="Один сервер"
# shellcheck disable=SC2034
PROFILE_DESCRIPTION="Развёртывание компонентов на одной VPS. HAProxy адаптирует уже установленную конфигурацию MTProxyL, а не устанавливается самостоятельно."
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
