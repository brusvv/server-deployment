#!/usr/bin/env bash
# shellcheck disable=SC2034
# VPS A is the Russian client-facing Entry.
# shellcheck disable=SC2034
PROFILE_ID="remnawave-cascade-entry"
# shellcheck disable=SC2034
PROFILE_TITLE="Каскад Remnawave — VPS A / Entry"
# shellcheck disable=SC2034
PROFILE_DESCRIPTION="Подготовка VPS A под российский Entry. Профиль выполняет preflight, резервное копирование и подготовку базовых пакетов; он не устанавливает и не регистрирует Remnawave Node, не создаёт VLESS inbound и не настраивает A→B маршрутизацию. Panel, eGamesAPI, Exit Node и MTProxyL здесь не устанавливаются."
# shellcheck disable=SC2034
PROFILE_STAGES=(
  preflight
  backup
  system
  validate
)
