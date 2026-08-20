#!/usr/bin/env bash

set -Eeuo pipefail
export LC_ALL=C
export PATH=/usr/local/bin:/usr/bin:/bin

readonly RUNTIME_DIR="/opt/vps-reality/runtime"
readonly CLIENTS_FILE="${RUNTIME_DIR}/clients.json"
readonly LOCK_FILE="${RUNTIME_DIR}/clients.lock"
readonly XRAY_BIN="/usr/local/bin/xray"
readonly XRAY_API="127.0.0.1:10085"
readonly INBOUND_TAG="vless-reality"

REQUEST_BODY=""
CLIENTS_TMP=""

# Invoked by the EXIT trap below.
# shellcheck disable=SC2329
cleanup() {
  [[ -z "$CLIENTS_TMP" ]] || rm -f "$CLIENTS_TMP"
}

trap cleanup EXIT

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

read_json_body() {
  local length=${CONTENT_LENGTH:-0}
  [[ "$length" =~ ^[0-9]+$ ]] || respond_error 400 "Bad Request" "Invalid Content-Length."
  ((length > 0 && length <= 16384)) \
    || respond_error 400 "Bad Request" "A non-empty JSON body up to 16 KiB is required."
  IFS= read -r -N "$length" REQUEST_BODY || true
  jq -e . >/dev/null 2>&1 <<<"$REQUEST_BODY" \
    || respond_error 400 "Bad Request" "Request body must be valid JSON."
}

restore_xray_user_best_effort() {
  local record=$1
  local config
  config=$(mktemp "${RUNTIME_DIR}/xray-restore.XXXXXX.json")
  jq -n \
    --argjson client "$record" \
    --arg tag "$INBOUND_TAG" \
    '{
      inbounds: [{
        tag: $tag,
        port: 443,
        protocol: "vless",
        settings: {
          clients: [{id: $client.id, email: $client.email, flow: "xtls-rprx-vision"}],
          decryption: "none"
        }
      }]
    }' >"$config"
  "$XRAY_BIN" api adu --server="$XRAY_API" "$config" >/dev/null 2>&1 || true
  rm -f "$config"
}

[[ ${REQUEST_METHOD:-} == "POST" ]] \
  || respond_error 405 "Method Not Allowed" "Use POST."
[[ ${CONTENT_TYPE:-} == application/json* ]] \
  || respond_error 415 "Unsupported Media Type" "Content-Type must be application/json."

read_json_body

CLIENT_ID=$(jq -er '.id | select(type == "string")' <<<"$REQUEST_BODY" 2>/dev/null) \
  || respond_error 400 "Bad Request" "A string id field is required."
[[ "$CLIENT_ID" =~ ^[0-9a-fA-F-]{36}$ ]] \
  || respond_error 400 "Bad Request" "Client id has an invalid format."

[[ -x "$XRAY_BIN" ]] || respond_error 500 "Internal Server Error" "Xray is not installed."
[[ -r "$CLIENTS_FILE" ]] || respond_error 500 "Internal Server Error" "Client database is unavailable."
jq -e '.clients | type == "array"' "$CLIENTS_FILE" >/dev/null 2>&1 \
  || respond_error 500 "Internal Server Error" "Client database is invalid."

exec 9>"$LOCK_FILE"
flock -x 9

RECORD=$(jq -c --arg id "$CLIENT_ID" '.clients[] | select(.id == $id)' "$CLIENTS_FILE")
if [[ -z "$RECORD" ]]; then
  respond 200 "OK" '{"removed":false}'
fi
EMAIL=$(jq -r '.email' <<<"$RECORD")

if ! XRAY_OUTPUT=$("$XRAY_BIN" api rmu --server="$XRAY_API" -tag="$INBOUND_TAG" -- "$EMAIL" 2>&1); then
  printf 'remove.sh: xray api rmu failed: %s\n' "$XRAY_OUTPUT" >&2
  respond_error 502 "Bad Gateway" "Xray rejected the removal."
fi
if ! grep -Fq 'Removed 1 user(s) in total.' <<<"$XRAY_OUTPUT"; then
  printf 'remove.sh: Xray did not remove the user: %s\n' "$XRAY_OUTPUT" >&2
  respond_error 502 "Bad Gateway" "Xray did not contain the requested client."
fi

CLIENTS_TMP=$(mktemp "${RUNTIME_DIR}/clients.XXXXXX.json")
if ! jq --arg id "$CLIENT_ID" '.clients |= map(select(.id != $id))' \
  "$CLIENTS_FILE" >"$CLIENTS_TMP"; then
  restore_xray_user_best_effort "$RECORD"
  respond_error 500 "Internal Server Error" "Could not update the client database."
fi
chgrp vps-reality "$CLIENTS_TMP"
chmod 0660 "$CLIENTS_TMP"
if ! mv -f "$CLIENTS_TMP" "$CLIENTS_FILE"; then
  restore_xray_user_best_effort "$RECORD"
  respond_error 500 "Internal Server Error" "Could not commit the client database."
fi
CLIENTS_TMP=""

respond 200 "OK" '{"removed":true}'
