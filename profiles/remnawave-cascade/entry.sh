#!/usr/bin/env bash
# VPS A is the Russian client-facing Entry.
PROFILE_ID="remnawave-cascade-entry"
PROFILE_TITLE="Каскад Remnawave — VPS A / Entry"
PROFILE_DESCRIPTION="Роль российского Entry-узла. Этот профиль не устанавливает Panel, eGamesAPI, Exit Node или MTProxyL. Настройка профиля Remnawave и A→B маршрутизации остаётся отдельной операцией."
PROFILE_STAGES=(
  preflight
  system
  validate
)
