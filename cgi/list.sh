#!/usr/bin/env bash

set -Eeuo pipefail
export LC_ALL=C
export PATH=/usr/local/bin:/usr/bin:/bin

readonly CLIENTS_FILE="/opt/vps-reality/runtime/clients.json"
readonly LOCK_FILE="/opt/vps-reality/runtime/clients.lock"

respond() {
  local status=$1
  local reason=$2
  local body=$3
  printf 'Status: %s %s\r\n' "$status" "$reason"
  printf 'Content-Type: application/json; charset=utf-8\r\n'
  printf 'Cache-Control: no-store\r\n'
  printf '\r\n'
  printf '%s\n' "$body"
  exit 0
}

respond_error() {
  local status=$1
  local reason=$2
  local message=$3
  local body
  body=$(jq -cn --arg error "$message" '{error: $error}')
  respond "$status" "$reason" "$body"
}

[[ ${REQUEST_METHOD:-} == "GET" ]] \
  || respond_error 405 "Method Not Allowed" "Use GET."
[[ -r "$CLIENTS_FILE" ]] \
  || respond_error 500 "Internal Server Error" "Client database is unavailable."

exec 9>"$LOCK_FILE"
flock -s 9

CLIENTS=$(jq -c '.clients | select(type == "array")' "$CLIENTS_FILE" 2>/dev/null) \
  || respond_error 500 "Internal Server Error" "Client database is invalid."
respond 200 "OK" "$CLIENTS"
