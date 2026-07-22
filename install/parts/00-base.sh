#!/usr/bin/env bash
# Container-side installer for proxmox-groupware-lxc.
# Installs SOGo with Authentik OIDC, a local Dovecot IMAP bridge and a
# sender-dependent Postfix relay for existing external mailboxes.

set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

readonly INSTALLER_VERSION="1.0.4"
readonly ENV_FILE="/root/groupware-installer.env"

log()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m   %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[FEHLER]\033[0m %s\n' "$*" >&2; exit 1; }

on_error() {
  local rc=$?
  printf '\n[FEHLER] Container-Installation in Zeile %s abgebrochen (Exit %s).\n' "${1:-?}" "$rc" >&2
  printf 'Logs: journalctl -u sogo -u dovecot -u postfix -u nginx --no-pager -n 200\n' >&2
  if [[ -f "$ENV_FILE" ]]; then
    printf 'Die Installationsdaten bleiben für einen erneuten Versuch unter %s erhalten.\n' "$ENV_FILE" >&2
  fi
  exit "$rc"
}
trap 'on_error "$LINENO"' ERR

[[ $EUID -eq 0 ]] || die "Dieses Skript muss im Container als root laufen."
[[ -r "$ENV_FILE" ]] || die "Installationsdatei fehlt: $ENV_FILE"
# shellcheck disable=SC1090
source "$ENV_FILE"

required_vars=(
  FQDN PUBLIC_URL TIMEZONE AUTHENTIK_URL OIDC_SLUG
  OIDC_CLIENT_ID_B64 OIDC_CLIENT_SECRET_B64
  FIRST_EMAIL_B64 FIRST_NAME_B64 MAIL_PASSWORD_B64
  IMAP_HOST IMAP_PORT SMTP_HOST SMTP_PORT
)
for var in "${required_vars[@]}"; do
  [[ -n "${!var:-}" ]] || die "Variable $var fehlt."
done

b64decode() { printf '%s' "$1" | base64 -d; }
OIDC_CLIENT_ID="$(b64decode "$OIDC_CLIENT_ID_B64")"
OIDC_CLIENT_SECRET="$(b64decode "$OIDC_CLIENT_SECRET_B64")"
FIRST_EMAIL="$(b64decode "$FIRST_EMAIL_B64")"
FIRST_NAME="$(b64decode "$FIRST_NAME_B64")"
MAIL_PASSWORD="$(b64decode "$MAIL_PASSWORD_B64")"
AUTHENTIK_URL="${AUTHENTIK_URL%/}"
PUBLIC_URL="${PUBLIC_URL%/}"
OIDC_DISCOVERY_URL="${AUTHENTIK_URL}/application/o/${OIDC_SLUG}/.well-known/openid-configuration"
OIDC_INTROSPECTION_URL="${AUTHENTIK_URL}/application/o/introspect/"
MAIL_DOMAIN="${FIRST_EMAIL#*@}"

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8

log "Aktualisiere Debian und installiere Grundpakete"
apt-get update
apt-get -y full-upgrade
printf 'postfix postfix/mailname string %s\n' "$FQDN" | debconf-set-selections
printf 'postfix postfix/main_mailer_type select No configuration\n' | debconf-set-selections
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg openssl debconf-utils \
  mariadb-server nginx memcached \
  dovecot-core dovecot-imapd dovecot-mysql \
  postfix postfix-mysql libsasl2-modules \
  python3 python3-pymysql python3-cryptography \
  jq netcat-openbsd zip

log "Aktiviere das offizielle freie SOGo-Nightly-Repository für Debian 12"
install -d -m 0755 /etc/apt/keyrings
curl -fsSL --retry 3 \
  'https://keys.openpgp.org/vks/v1/by-fingerprint/74FFC6D72B925A34B5D356BDF8A27B36A6E2EAE9' \
  | gpg --dearmor --yes -o /etc/apt/keyrings/sogo.gpg
cat >/etc/apt/sources.list.d/sogo.list <<'EOF'
deb [arch=amd64 signed-by=/etc/apt/keyrings/sogo.gpg] https://packages.sogo.nu/nightly/5/debian/ bookworm bookworm
EOF
apt-get update
apt-get install -y --no-install-recommends sogo sope4.9-gdl1-mysql
SOGO_VERSION="$(dpkg-query -W -f='${Version}' sogo)"
dpkg --compare-versions "$SOGO_VERSION" ge '5.12.9' || die "SOGo >= 5.12.9 erforderlich, installiert ist $SOGO_VERSION."

# Das freie Repository liefert Nightly-Builds. Nur tatsächlich installierte
# SOGo-/SOPE-Pakete festhalten. dpkg-query liefert bei Wildcards teilweise
# auch bekannte, aber nicht installierte Paketnamen; apt-mark lehnt diese ab.
mapfile -t SOGO_HOLD_PACKAGES < <(
  { dpkg-query -W -f='${binary:Package}\t${db:Status-Abbrev}\n' \
      'sogo*' 'sope*' 'libsope*' 2>/dev/null || true; } |
    awk '$2 ~ /^ii/ {sub(/:.*/, "", $1); print $1}' |
    sort -u
)
if (( ${#SOGO_HOLD_PACKAGES[@]} > 0 )); then
  apt-mark hold "${SOGO_HOLD_PACKAGES[@]}" >/dev/null
fi

systemctl stop sogo dovecot postfix nginx 2>/dev/null || true
systemctl enable mariadb memcached dovecot postfix nginx sogo >/dev/null
systemctl restart mariadb memcached

timedatectl set-timezone "$TIMEZONE" 2>/dev/null || true

log "Erzeuge Datenbank und lokale Dienstkonten"
DB_NAME="groupware"
DB_USER="groupware"
DB_PASSWORD="$(openssl rand -hex 24)"
AES_KEY_HEX="$(openssl rand -hex 32)"

if ! getent group vmail >/dev/null; then
  groupadd --system --gid 2000 vmail
fi
if ! id vmail >/dev/null 2>&1; then
  useradd --system --uid 2000 --gid vmail --home-dir /var/lib/groupware/mail \
    --create-home --shell /usr/sbin/nologin vmail
fi
install -d -o vmail -g vmail -m 0750 /var/lib/groupware/mail
install -d -o root -g root -m 0700 /etc/groupware

mariadb <<SQL
CREATE DATABASE IF NOT EXISTS ${DB_NAME}
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
USE ${DB_NAME};
CREATE TABLE IF NOT EXISTS users (
  c_uid VARCHAR(255) NOT NULL PRIMARY KEY,
  c_name VARCHAR(255) NOT NULL,
  c_password VARCHAR(255) NULL,
  c_cn VARCHAR(255) NOT NULL,
  mail VARCHAR(255) NOT NULL UNIQUE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE TABLE IF NOT EXISTS mail_accounts (
  email VARCHAR(255) NOT NULL PRIMARY KEY,
  imap_host VARCHAR(255) NOT NULL,
  imap_port INT UNSIGNED NOT NULL DEFAULT 993,
  imap_user VARCHAR(255) NOT NULL,
  imap_password VARBINARY(2048) NOT NULL,
  smtp_host VARCHAR(255) NOT NULL,
  smtp_port INT UNSIGNED NOT NULL DEFAULT 587,
  smtp_user VARCHAR(255) NOT NULL,
  smtp_password VARBINARY(2048) NOT NULL,
  enabled TINYINT(1) NOT NULL DEFAULT 1,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  CONSTRAINT fk_mail_account_user FOREIGN KEY (email)
    REFERENCES users(mail) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
SQL

cat >/etc/groupware/config.json <<EOF
{
  "database": {
    "host": "127.0.0.1",
    "name": "${DB_NAME}",
    "user": "${DB_USER}",
    "password": "${DB_PASSWORD}"
  },
  "aes_key_hex": "${AES_KEY_HEX}",
  "defaults": {
    "imap_host": "${IMAP_HOST}",
    "imap_port": ${IMAP_PORT},
    "smtp_host": "${SMTP_HOST}",
    "smtp_port": ${SMTP_PORT}
  }
}
EOF
chmod 0600 /etc/groupware/config.json
