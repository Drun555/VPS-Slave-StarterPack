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
XRAY_CONFIG_TMP=""
CLIENTS_TMP=""

# Invoked by the EXIT trap below.
# shellcheck disable=SC2329
cleanup() {
  [[ -z "$XRAY_CONFIG_TMP" ]] || rm -f "$XRAY_CONFIG_TMP"
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

add_xray_user() {
  local id=$1
  local email=$2
  local output

  XRAY_CONFIG_TMP=$(mktemp "${RUNTIME_DIR}/xray-add.XXXXXX.json")
  jq -n \
    --arg id "$id" \
    --arg email "$email" \
    --arg tag "$INBOUND_TAG" \
    '{
      inbounds: [{
        tag: $tag,
        port: 443,
        protocol: "vless",
        settings: {
          clients: [{id: $id, email: $email, flow: "xtls-rprx-vision"}],
          decryption: "none"
        }
      }]
    }' >"$XRAY_CONFIG_TMP"

  if ! output=$("$XRAY_BIN" api adu --server="$XRAY_API" "$XRAY_CONFIG_TMP" 2>&1); then
    printf 'register.sh: xray api adu failed: %s\n' "$output" >&2
    return 1
  fi
  if ! grep -Fq 'Added 1 user(s) in total.' <<<"$output"; then
    printf 'register.sh: Xray did not add the user: %s\n' "$output" >&2
    return 1
  fi
}

remove_xray_user_best_effort() {
  local email=$1
  "$XRAY_BIN" api rmu --server="$XRAY_API" -tag="$INBOUND_TAG" -- "$email" \
    >/dev/null 2>&1 || true
}

[[ ${REQUEST_METHOD:-} == "POST" ]] \
  || respond_error 405 "Method Not Allowed" "Use POST."
[[ ${CONTENT_TYPE:-} == application/json* ]] \
  || respond_error 415 "Unsupported Media Type" "Content-Type must be application/json."

read_json_body

EMAIL=$(jq -er '.email | select(type == "string")' <<<"$REQUEST_BODY" 2>/dev/null) \
  || respond_error 400 "Bad Request" "A string email field is required."
(( ${#EMAIL} <= 254 )) \
  || respond_error 400 "Bad Request" "Email is too long."
[[ "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] \
  || respond_error 400 "Bad Request" "Email has an invalid format."

[[ -x "$XRAY_BIN" ]] || respond_error 500 "Internal Server Error" "Xray is not installed."
[[ -r "$CLIENTS_FILE" ]] || respond_error 500 "Internal Server Error" "Client database is unavailable."
jq -e '.clients | type == "array"' "$CLIENTS_FILE" >/dev/null 2>&1 \
  || respond_error 500 "Internal Server Error" "Client database is invalid."

exec 9>"$LOCK_FILE"
flock -x 9

if jq -e --arg email "$EMAIL" 'any(.clients[]; .email == $email)' "$CLIENTS_FILE" >/dev/null; then
  respond_error 409 "Conflict" "A client with this email already exists."
fi

CLIENT_ID=$("$XRAY_BIN" uuid | tr -d '\r\n')
[[ "$CLIENT_ID" =~ ^[0-9a-fA-F-]{36}$ ]] \
  || respond_error 500 "Internal Server Error" "Xray returned an invalid UUID."

DOMAIN=$(<"${RUNTIME_DIR}/domain")
REALITY_PUBLIC_KEY=$(<"${RUNTIME_DIR}/reality-public-key")
REALITY_SHORT_ID=$(<"${RUNTIME_DIR}/reality-short-id")
EMAIL_FRAGMENT=$(jq -nr --arg value "$EMAIL" '$value | @uri')
CREATED_AT=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

VLESS_URI="vless://${CLIENT_ID}@${DOMAIN}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp#${EMAIL_FRAGMENT}"

add_xray_user "$CLIENT_ID" "$EMAIL" \
  || respond_error 502 "Bad Gateway" "Xray rejected the new client."

CLIENTS_TMP=$(mktemp "${RUNTIME_DIR}/clients.XXXXXX.json")
if ! jq \
  --arg id "$CLIENT_ID" \
  --arg email "$EMAIL" \
  --arg uri "$VLESS_URI" \
  --arg created_at "$CREATED_AT" \
  '.clients += [{id: $id, email: $email, uri: $uri, created_at: $created_at}]' \
  "$CLIENTS_FILE" >"$CLIENTS_TMP"; then
  remove_xray_user_best_effort "$EMAIL"
  respond_error 500 "Internal Server Error" "Could not update the client database."
fi

chgrp vps-reality "$CLIENTS_TMP"
chmod 0660 "$CLIENTS_TMP"
if ! mv -f "$CLIENTS_TMP" "$CLIENTS_FILE"; then
  remove_xray_user_best_effort "$EMAIL"
  respond_error 500 "Internal Server Error" "Could not commit the client database."
fi
CLIENTS_TMP=""

RESPONSE=$(jq -cn \
  --arg id "$CLIENT_ID" \
  --arg email "$EMAIL" \
  --arg uri "$VLESS_URI" \
  --arg created_at "$CREATED_AT" \
  '{id: $id, email: $email, uri: $uri, created_at: $created_at}')
respond 201 "Created" "$RESPONSE"
