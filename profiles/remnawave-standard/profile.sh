#!/usr/bin/env bash
# shellcheck disable=SC2034
# Minimal single-host Remnawave installation: Panel + local Node only.
# shellcheck disable=SC2034
PROFILE_ID="remnawave-standard"
# shellcheck disable=SC2034
PROFILE_TITLE="Обычная установка Remnawave — Panel + Node"
# shellcheck disable=SC2034
PROFILE_DESCRIPTION="Установка eGamesAPI: Remnawave Panel + локальная Node, а также bundled subscription page/reverse proxy. Важно: upstream не рекомендует комбинированный Panel + Node режим для production. Не запускает MTProxyL, HAProxy, WARP/MASQUE или дополнительные сетевые адаптеры."
# shellcheck disable=SC2034
PROFILE_STAGES=(
  preflight
  backup
  system
  remnawave
  validate
)
