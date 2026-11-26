#!/usr/bin/env bash
# shellcheck disable=SC2034
# VPS A is the Russian client-facing Entry.
# shellcheck disable=SC2034
PROFILE_ID="remnawave-cascade-entry"
# shellcheck disable=SC2034
PROFILE_TITLE="Каскад Remnawave — VPS A / Entry"
# shellcheck disable=SC2034
PROFILE_DESCRIPTION="Роль российского Entry-узла. Этот профиль не устанавливает Panel, eGamesAPI, Exit Node или MTProxyL. Настройка профиля Remnawave и A→B маршрутизации остаётся отдельной операцией."
# shellcheck disable=SC2034
PROFILE_STAGES=(
  preflight
  backup
  system
  validate
)
