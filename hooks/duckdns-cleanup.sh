#!/usr/bin/env bash

set -Eeuo pipefail
export LC_ALL=C
export PATH=/usr/local/bin:/usr/bin:/bin

readonly TOKEN_FILE="/opt/vps-reality/runtime/duckdns-token"
readonly DUCKDNS_API="https://www.duckdns.org/update"

DOMAIN=${CERTBOT_IDENTIFIER:-${CERTBOT_DOMAIN:-}}

[[ -n "$DOMAIN" ]] || { printf 'DuckDNS cleanup: missing CERTBOT_IDENTIFIER.\n' >&2; exit 1; }
[[ "$DOMAIN" == *.duckdns.org ]] \
  || { printf 'DuckDNS cleanup: only *.duckdns.org domains are supported.\n' >&2; exit 1; }
[[ -r "$TOKEN_FILE" ]] || { printf 'DuckDNS cleanup: token file is unavailable.\n' >&2; exit 1; }

TOKEN=$(<"$TOKEN_FILE")
SUBDOMAIN=${DOMAIN%.duckdns.org}

RESPONSE=$(curl -fsS --get "$DUCKDNS_API" \
  --data-urlencode "domains=${SUBDOMAIN}" \
  --data-urlencode "token=${TOKEN}" \
  --data-urlencode "txt=" \
  --data-urlencode "clear=true" \
  --data-urlencode "verbose=true")

[[ ${RESPONSE%%$'\n'*} == "OK" ]] \
  || { printf 'DuckDNS cleanup failed: %s\n' "$RESPONSE" >&2; exit 1; }

printf 'DuckDNS TXT record cleared.\n'
