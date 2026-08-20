#!/usr/bin/env bash

set -Eeuo pipefail

readonly INSTALL_DIR="/opt/vps-reality"
readonly RUNTIME_DIR="${INSTALL_DIR}/runtime"
readonly NGINX_SITE="/etc/nginx/sites-available/vps-reality"
readonly NGINX_SITE_LINK="/etc/nginx/sites-enabled/vps-reality"
readonly CERTBOT_DEPLOY_HOOK="/etc/letsencrypt/renewal-hooks/deploy/vps-reality-nginx.sh"
readonly SSH_OVERRIDE="/etc/ssh/sshd_config.d/00-vps-reality.conf"

CURRENT_STAGE="argument parsing"
ASSUME_YES=false
DOMAIN=""

log() {
  printf '[vps-reality] %s\n' "$*"
}

warn() {
  printf '[vps-reality] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[vps-reality] ERROR: %s\n' "$*" >&2
  exit 1
}

on_error() {
  local exit_code=$?
  printf '[vps-reality] ERROR: uninstall stage "%s" failed at line %s (exit %s).\n' \
    "$CURRENT_STAGE" "${BASH_LINENO[0]:-unknown}" "$exit_code" >&2
  exit "$exit_code"
}

trap on_error ERR

usage() {
  cat <<'EOF'
Usage:
  sudo /opt/vps-reality/uninstall.sh --yes [--domain example.duckdns.org]

Options:
  --yes       Confirm deletion of the VPS Reality installation and runtime data.
  --domain    Certificate name to remove when runtime/domain is unavailable.
  -h, --help  Show this help text.

The uninstaller intentionally keeps Ubuntu packages, the root authorized_keys
file, the SSH firewall rule, UFW's enabled state, and the Certbot account.
EOF
}

require_value() {
  local option=$1
  local value=${2:-}
  [[ -n "$value" ]] || die "${option} requires a value."
}

parse_arguments() {
  while (($# > 0)); do
    case "$1" in
      --yes)
        ASSUME_YES=true
        shift
        ;;
      --domain)
        (($# >= 2)) || die "--domain requires a value."
        DOMAIN=$2
        require_value "--domain" "$DOMAIN"
        shift 2
        ;;
      --domain=*)
        DOMAIN=${1#*=}
        require_value "--domain" "$DOMAIN"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done

  [[ "$ASSUME_YES" == true ]] || die "Refusing destructive cleanup without --yes."
  if [[ -n "$DOMAIN" ]]; then
    [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+\.duckdns\.org$ ]] \
      || die "--domain must be a *.duckdns.org hostname."
    DOMAIN=${DOMAIN,,}
  fi
}

remove_managed_tree() {
  local target=$1
  local resolved

  case "$target" in
    /opt/vps-reality|/usr/local/etc/xray|/usr/local/share/xray|/var/log/xray|\
    /etc/systemd/system/xray.service.d|/etc/systemd/system/xray@.service.d)
      ;;
    *)
      die "Refusing to recursively remove unexpected path: ${target}"
      ;;
  esac

  [[ -e "$target" || -L "$target" ]] || return 0
  [[ ! -L "$target" ]] || die "Refusing to recursively remove symlink: ${target}"
  resolved=$(readlink -f -- "$target")
  [[ "$resolved" == "$target" ]] \
    || die "Refusing to recursively remove unexpectedly resolved path: ${resolved}"
  rm -rf -- "$target"
}

discover_domain() {
  if [[ -z "$DOMAIN" && -r "${RUNTIME_DIR}/domain" ]]; then
    IFS= read -r DOMAIN <"${RUNTIME_DIR}/domain" || true
    DOMAIN=${DOMAIN%$'\r'}
    DOMAIN=${DOMAIN,,}
  fi

  if [[ -n "$DOMAIN" && ! "$DOMAIN" =~ ^[a-z0-9.-]+\.duckdns\.org$ ]]; then
    warn "Ignoring an invalid certificate name found in runtime/domain."
    DOMAIN=""
  fi
}

remove_xray() {
  CURRENT_STAGE="Xray removal"
  log "Stopping and removing Xray Core..."

  systemctl disable --now xray.service >/dev/null 2>&1 || true
  rm -f \
    /etc/systemd/system/xray.service \
    /etc/systemd/system/xray@.service
  remove_managed_tree /etc/systemd/system/xray.service.d
  remove_managed_tree /etc/systemd/system/xray@.service.d
  rm -f /usr/local/bin/xray
  remove_managed_tree /usr/local/etc/xray
  remove_managed_tree /usr/local/share/xray
  remove_managed_tree /var/log/xray
}

remove_certificate() {
  CURRENT_STAGE="certificate removal"
  rm -f "$CERTBOT_DEPLOY_HOOK"

  [[ -n "$DOMAIN" ]] || {
    warn "Certificate domain is unknown; no Certbot certificate was deleted."
    return
  }

  if command -v certbot >/dev/null 2>&1 \
    && { [[ -e "/etc/letsencrypt/renewal/${DOMAIN}.conf" ]] \
      || [[ -d "/etc/letsencrypt/live/${DOMAIN}" ]]; }; then
    log "Deleting the Certbot certificate named ${DOMAIN}..."
    certbot delete --non-interactive --cert-name "$DOMAIN"
  else
    log "No Certbot certificate named ${DOMAIN} is present."
  fi
}

remove_nginx_site() {
  CURRENT_STAGE="Nginx cleanup"
  log "Removing the VPS Reality Nginx site..."

  rm -f "$NGINX_SITE_LINK" "$NGINX_SITE"
  if [[ -f /etc/nginx/sites-available/default \
    && ! -e /etc/nginx/sites-enabled/default ]]; then
    ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
  fi

  if command -v nginx >/dev/null 2>&1; then
    nginx -t
    systemctl reload nginx.service >/dev/null 2>&1 || true
  fi
}

restore_ssh_configuration() {
  CURRENT_STAGE="SSH cleanup"
  if [[ ! -e "$SSH_OVERRIDE" ]]; then
    log "No VPS Reality SSH override is present."
    return
  fi

  log "Removing the VPS Reality SSH override..."
  rm -f "$SSH_OVERRIDE"
  sshd -t
  systemctl reload ssh.service
}

remove_firewall_rule() {
  CURRENT_STAGE="firewall cleanup"
  command -v ufw >/dev/null 2>&1 || return 0

  if ufw status | awk '$1 == "443/tcp" {found=1} END {exit !found}'; then
    log "Removing the UFW allow rule for 443/tcp..."
    ufw --force delete allow 443/tcp >/dev/null
  fi
}

remove_runtime() {
  CURRENT_STAGE="runtime cleanup"
  log "Removing ${INSTALL_DIR} and generated credentials..."
  remove_managed_tree "$INSTALL_DIR"
  groupdel vps-reality >/dev/null 2>&1 || true
}

finish() {
  CURRENT_STAGE="finalization"
  systemctl daemon-reload
  systemctl reset-failed xray.service >/dev/null 2>&1 || true

  cat <<'EOF'

VPS Reality artifacts were removed.

Kept intentionally:
  - Ubuntu packages installed or upgraded by setup.sh
  - /root/.ssh/authorized_keys and the SSH UFW rule
  - UFW's current enabled/disabled state
  - the Let's Encrypt account and certbot.timer
EOF
}

main() {
  parse_arguments "$@"
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run this uninstaller as root."

  discover_domain
  log "Removing VPS Reality${DOMAIN:+ for ${DOMAIN}}..."
  remove_xray
  remove_certificate
  remove_nginx_site
  restore_ssh_configuration
  remove_firewall_rule
  remove_runtime
  finish
}

main "$@"
