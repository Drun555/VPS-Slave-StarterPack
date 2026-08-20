#!/usr/bin/env bash

set -Eeuo pipefail
export LC_ALL=C
export PATH=/usr/local/bin:/usr/bin:/bin

readonly TOKEN_FILE="/opt/vps-reality/runtime/duckdns-token"
readonly DUCKDNS_API="https://www.duckdns.org/update"

DOMAIN=${CERTBOT_IDENTIFIER:-${CERTBOT_DOMAIN:-}}
VALIDATION=${CERTBOT_VALIDATION:-}

[[ -n "$DOMAIN" ]] || { printf 'DuckDNS auth: missing CERTBOT_IDENTIFIER.\n' >&2; exit 1; }
[[ -n "$VALIDATION" ]] || { printf 'DuckDNS auth: missing CERTBOT_VALIDATION.\n' >&2; exit 1; }
[[ "$DOMAIN" == *.duckdns.org ]] \
  || { printf 'DuckDNS auth: only *.duckdns.org domains are supported.\n' >&2; exit 1; }
[[ -r "$TOKEN_FILE" ]] || { printf 'DuckDNS auth: token file is unavailable.\n' >&2; exit 1; }

TOKEN=$(<"$TOKEN_FILE")
SUBDOMAIN=${DOMAIN%.duckdns.org}

RESPONSE=$(curl -fsS --get "$DUCKDNS_API" \
  --data-urlencode "domains=${SUBDOMAIN}" \
  --data-urlencode "token=${TOKEN}" \
  --data-urlencode "txt=${VALIDATION}" \
  --data-urlencode "verbose=true")

[[ ${RESPONSE%%$'\n'*} == "OK" ]] \
  || { printf 'DuckDNS auth failed: %s\n' "$RESPONSE" >&2; exit 1; }

PROPAGATION_SECONDS=${DUCKDNS_PROPAGATION_SECONDS:-60}
[[ "$PROPAGATION_SECONDS" =~ ^[0-9]+$ ]] \
  || { printf 'DuckDNS auth: invalid propagation delay.\n' >&2; exit 1; }

printf 'DuckDNS TXT record updated; waiting %s seconds for propagation.\n' "$PROPAGATION_SECONDS"
sleep "$PROPAGATION_SECONDS"
