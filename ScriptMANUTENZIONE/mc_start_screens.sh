#!/usr/bin/env bash
set -euo pipefail

timedatectl set-timezone Europe/Rome || true

SCREENS=(imperium hub velocity afk)

declare -A START_CMDS=(
  [imperium]='cd /home/imperium/imperium && ./start.sh'
  [hub]='cd /home/imperium/hub && ./start.sh'
  [velocity]='cd /home/imperium/velocity && ./start.sh'
  [afk]='cd /home/imperium/afk && ./start.sh'
)

screen_exists() {
  local name="$1"
  screen -list | grep -q "\.${name}[[:space:]]"
}

start_screen_if_not_exists() {
  local name="$1"
  local run_cmd="$2"
  if ! screen_exists "$name"; then
    screen -dmS "${name}" bash -c "${run_cmd}; exec bash"
  fi
}

start_screen_if_not_exists imperium "${START_CMDS[imperium]}"
sleep 30
start_screen_if_not_exists hub "${START_CMDS[hub]}"
sleep 30
start_screen_if_not_exists velocity "${START_CMDS[velocity]}"
sleep 20
start_screen_if_not_exists afk "${START_CMDS[afk]}"
