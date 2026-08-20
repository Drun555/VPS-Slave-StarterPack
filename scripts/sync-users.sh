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

TEMP_CONFIG=""

cleanup() {
  [[ -z "$TEMP_CONFIG" ]] || rm -f "$TEMP_CONFIG"
}

trap cleanup EXIT

[[ -r "$CLIENTS_FILE" ]] || { printf 'sync-users: client database is unavailable.\n' >&2; exit 1; }
jq -e '.clients | type == "array"' "$CLIENTS_FILE" >/dev/null \
  || { printf 'sync-users: client database is invalid.\n' >&2; exit 1; }

exec 9>"$LOCK_FILE"
flock -x 9

CLIENT_COUNT=$(jq '.clients | length' "$CLIENTS_FILE")
((CLIENT_COUNT > 0)) || exit 0

API_READY=false
for _ in $(seq 1 30); do
  if "$XRAY_BIN" api inboundusercount --server="$XRAY_API" -tag="$INBOUND_TAG" \
    >/dev/null 2>&1; then
    API_READY=true
    break
  fi
  sleep 1
done

[[ "$API_READY" == true ]] \
  || { printf 'sync-users: Xray API did not become ready.\n' >&2; exit 1; }

TEMP_CONFIG=$(mktemp "${RUNTIME_DIR}/xray-sync.XXXXXX.json")
jq \
  --arg tag "$INBOUND_TAG" \
  '{
    inbounds: [{
      tag: $tag,
      port: 443,
      protocol: "vless",
      settings: {
        clients: [.clients[] | {id: .id, email: .email, flow: "xtls-rprx-vision"}],
        decryption: "none"
      }
    }]
  }' "$CLIENTS_FILE" >"$TEMP_CONFIG"

if ! OUTPUT=$("$XRAY_BIN" api adu --server="$XRAY_API" "$TEMP_CONFIG" 2>&1); then
  printf 'sync-users: xray api adu failed: %s\n' "$OUTPUT" >&2
  exit 1
fi

EXPECTED="Added ${CLIENT_COUNT} user(s) in total."
if ! grep -Fq "$EXPECTED" <<<"$OUTPUT"; then
  printf 'sync-users: expected "%s", got: %s\n' "$EXPECTED" "$OUTPUT" >&2
  exit 1
fi

printf 'sync-users: restored %s client(s).\n' "$CLIENT_COUNT"
