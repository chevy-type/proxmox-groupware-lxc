#!/usr/bin/env bash
# Proxmox LXC installer for SOGo Groupware with Authentik OIDC.
# Creates a fresh Debian 12 LXC and installs a webmail client for existing
# external IMAP/SMTP accounts. It does not create a public mail server.

set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

readonly SCRIPT_VERSION="1.0.0"
readonly DEBIAN_VERSION="12"
readonly DEFAULT_FQDN="post.momenteschenker.de"
readonly DEFAULT_IP="192.168.178.61/24"
readonly DEFAULT_GATEWAY="192.168.178.1"
readonly DEFAULT_DNS="192.168.178.1 1.1.1.1"
readonly DEFAULT_AUTHENTIK="https://anmeldung.momenteschenker.de"
readonly DEFAULT_OIDC_SLUG="sogo"
readonly DEFAULT_TIMEZONE="Europe/Berlin"
readonly INSTALL_URL="${INSTALL_URL:-https://raw.githubusercontent.com/chevy-type/proxmox-groupware-lxc/main/install/groupware-install.sh}"

WORKDIR="$(mktemp -d /tmp/groupware-lxc.XXXXXX)"
CREATED_CT=0
CTID=""

cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

info()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m[OK]\033[0m   %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m[FEHLER]\033[0m %s\n' "$*" >&2; exit 1; }

on_error() {
  local rc=$?
  echo
  echo "FEHLER: Installation in Zeile ${1:-?} abgebrochen (Exit ${rc})." >&2
  if [[ "$CREATED_CT" -eq 1 && -n "$CTID" ]]; then
    echo "Der LXC ${CTID} bleibt zur Diagnose bestehen." >&2
    echo "Konsole: pct enter ${CTID}" >&2
  fi
  exit "$rc"
}
trap 'on_error "$LINENO"' ERR

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Befehl fehlt: $1"; }
prompt_default() {
  local prompt="$1" default="$2" value
  read -r -p "${prompt} [${default}]: " value
  printf '%s' "${value:-$default}"
}
prompt_secret() {
  local prompt="$1" value
  read -r -s -p "$prompt" value
  echo >&2
  printf '%s' "$value"
}
validate_fqdn() { [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]; }
validate_host() { validate_fqdn "$1" || validate_ipv4 "$1"; }
validate_ipv4() {
  local value="$1" octet
  [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a octets <<<"$value"
  for octet in "${octets[@]}"; do (( octet >= 0 && octet <= 255 )) || return 1; done
}
validate_ipv4_cidr() {
  local value="$1"
  [[ "$value" =~ ^(.+)/([0-9]|[12][0-9]|3[0-2])$ ]] || return 1
  validate_ipv4 "${value%/*}"
}
storage_default() {
  pvesm status -content "$1" 2>/dev/null | awk 'NR>1 && $3=="active" {print $1; exit}'
}
storage_supports() {
  pvesm status -content "$2" 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "$1"
}
b64() { printf '%s' "$1" | base64 -w0; }

[[ $EUID -eq 0 ]] || die "Bitte als root auf dem Proxmox-Host ausführen."
for cmd in pct pveam pvesm pvesh pveversion curl openssl base64 awk grep; do require_cmd "$cmd"; done
pveversion >/dev/null 2>&1 || die "Dieses Skript muss auf Proxmox VE laufen."

echo
echo "============================================================"
echo " SOGo Groupware LXC Installer ${SCRIPT_VERSION}"
echo " OIDC-Webmail, Kalender und Kontakte für externe Mailkonten"
echo "============================================================"
echo
echo "Dieser Installer richtet KEINEN öffentlichen Mailserver ein."
echo "Er verwendet vorhandene IMAP/SMTP-Postfächer, zunächst IONOS."
echo

NEXTID="$(pvesh get /cluster/nextid)"
TEMPLATE_STORAGE_DEFAULT="$(storage_default vztmpl)"
CT_STORAGE_DEFAULT="$(storage_default rootdir)"
[[ -n "$TEMPLATE_STORAGE_DEFAULT" ]] || die "Kein Template-Storage gefunden."
[[ -n "$CT_STORAGE_DEFAULT" ]] || die "Kein LXC-Storage gefunden."

CTID="$(prompt_default 'Container-ID' "$NEXTID")"
[[ "$CTID" =~ ^[0-9]+$ ]] || die "Ungültige Container-ID."
pct status "$CTID" >/dev/null 2>&1 && die "Container-ID ${CTID} ist bereits belegt."

while true; do
  FQDN="$(prompt_default 'Öffentlicher Groupware-FQDN' "$DEFAULT_FQDN")"
  FQDN="${FQDN,,}"
  validate_fqdn "$FQDN" && break
  warn "Ungültiger FQDN."
done
PUBLIC_URL="https://${FQDN}"

while true; do
  IP_CIDR="$(prompt_default 'Statische IPv4-Adresse mit CIDR' "$DEFAULT_IP")"
  validate_ipv4_cidr "$IP_CIDR" && break
  warn "Beispiel: 192.168.178.61/24"
done
while true; do
  GATEWAY="$(prompt_default 'IPv4-Gateway' "$DEFAULT_GATEWAY")"
  validate_ipv4 "$GATEWAY" && break
  warn "Ungültige IPv4-Adresse."
done
while true; do
  NAMESERVER="$(prompt_default 'DNS-Server (mehrere durch Leerzeichen)' "$DEFAULT_DNS")"
  DNS_VALID=1
  read -r -a DNS_SERVERS <<<"$NAMESERVER"
  [[ ${#DNS_SERVERS[@]} -gt 0 ]] || DNS_VALID=0
  for DNS_SERVER in "${DNS_SERVERS[@]}"; do
    validate_ipv4 "$DNS_SERVER" || DNS_VALID=0
  done
  [[ "$DNS_VALID" -eq 1 ]] && break
  warn "Bitte gültige IPv4-Adressen durch Leerzeichen getrennt angeben."
done

BRIDGE="$(prompt_default 'Proxmox-Bridge' 'vmbr0')"
TEMPLATE_STORAGE="$(prompt_default 'Template-Storage' "$TEMPLATE_STORAGE_DEFAULT")"
CT_STORAGE="$(prompt_default 'Container-Storage' "$CT_STORAGE_DEFAULT")"
CORES="$(prompt_default 'CPU-Kerne' '2')"
RAM="$(prompt_default 'RAM in MB' '2048')"
SWAP="$(prompt_default 'Swap in MB' '1024')"
DISK="$(prompt_default 'Root-Disk in GB' '12')"
TIMEZONE="$(prompt_default 'Zeitzone' "$DEFAULT_TIMEZONE")"
[[ "$TIMEZONE" =~ ^[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)*$ && -e "/usr/share/zoneinfo/$TIMEZONE" ]] || die "Ungültige Zeitzone."

[[ "$CORES" =~ ^[1-9][0-9]*$ ]] || die "Ungültige CPU-Anzahl."
[[ "$RAM" =~ ^[1-9][0-9]*$ ]] || die "Ungültiger RAM-Wert."
[[ "$SWAP" =~ ^[0-9]+$ ]] || die "Ungültiger Swap-Wert."
[[ "$DISK" =~ ^[1-9][0-9]*$ ]] || die "Ungültige Disk-Größe."
storage_supports "$TEMPLATE_STORAGE" vztmpl || die "Storage ${TEMPLATE_STORAGE} unterstützt keine Templates."
storage_supports "$CT_STORAGE" rootdir || die "Storage ${CT_STORAGE} unterstützt keine LXC-RootFS."

while true; do
  AUTHENTIK_URL="$(prompt_default 'Authentik-URL' "$DEFAULT_AUTHENTIK")"
  AUTHENTIK_URL="${AUTHENTIK_URL%/}"
  [[ "$AUTHENTIK_URL" =~ ^https://([a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?|\[[0-9a-fA-F:]+\])(:[0-9]{1,5})?$ ]] && break
  warn "Bitte eine HTTPS-Basis-URL ohne Pfad eingeben, z. B. https://anmeldung.example.org."
done
OIDC_SLUG="$(prompt_default 'Authentik-Anwendungs-Slug' "$DEFAULT_OIDC_SLUG")"
[[ "$OIDC_SLUG" =~ ^[a-zA-Z0-9._-]+$ ]] || die "Ungültiger Authentik-Slug."
AUTHENTIK_INTERNAL_IP="$(prompt_default 'Interne IP für Authentik/Traefik (leer = normales DNS)' '')"
if [[ -n "$AUTHENTIK_INTERNAL_IP" ]]; then validate_ipv4 "$AUTHENTIK_INTERNAL_IP" || die "Ungültige interne Authentik-IP."; fi

echo
echo "Authentik muss einen vertraulichen OAuth2/OIDC-Provider besitzen:"
echo "  Redirect URI: ${PUBLIC_URL}/SOGo/"
echo "  Scopes:       openid profile email offline_access"
echo "  Discovery:    ${AUTHENTIK_URL}/application/o/${OIDC_SLUG}/.well-known/openid-configuration"
echo
OIDC_CLIENT_ID="$(prompt_default 'OIDC Client-ID' '')"
[[ -n "$OIDC_CLIENT_ID" ]] || die "OIDC Client-ID darf nicht leer sein."
OIDC_CLIENT_SECRET="$(prompt_secret 'OIDC Client-Secret: ')"
[[ -n "$OIDC_CLIENT_SECRET" ]] || die "OIDC Client-Secret darf nicht leer sein."

FIRST_EMAIL="$(prompt_default 'Erster Benutzer / IONOS-Mailadresse' 'bernd@momenteschenker.de')"
FIRST_EMAIL="${FIRST_EMAIL,,}"
[[ "$FIRST_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die "Ungültige Mailadresse."
FIRST_NAME="$(prompt_default 'Anzeigename' 'Bernd Köhler')"
MAIL_PASSWORD="$(prompt_secret 'IONOS-Mailpasswort: ')"
[[ -n "$MAIL_PASSWORD" ]] || die "Mailpasswort darf nicht leer sein."
IMAP_HOST="$(prompt_default 'IMAP-Server' 'imap.ionos.de')"
validate_host "$IMAP_HOST" || die "Ungültiger IMAP-Hostname."
IMAP_PORT="$(prompt_default 'IMAP-Port (SSL/TLS)' '993')"
SMTP_HOST="$(prompt_default 'SMTP-Server' 'smtp.ionos.de')"
validate_host "$SMTP_HOST" || die "Ungültiger SMTP-Hostname."
SMTP_PORT="$(prompt_default 'SMTP-Port (STARTTLS)' '587')"
[[ "$IMAP_PORT" =~ ^[0-9]+$ && "$SMTP_PORT" =~ ^[0-9]+$ ]] || die "Ungültiger Port."

CONTAINER_IP="${IP_CIDR%/*}"
if ping -c 1 -W 1 "$CONTAINER_IP" >/dev/null 2>&1; then
  die "${CONTAINER_IP} antwortet bereits. Bitte eine freie IP verwenden."
fi

echo
echo "Geplante Installation:"
echo "  LXC:              ${CTID} / Debian ${DEBIAN_VERSION} / ${CONTAINER_IP}"
echo "  Web:              ${PUBLIC_URL}/SOGo/"
echo "  Authentik:        ${AUTHENTIK_URL} (Slug ${OIDC_SLUG})"
echo "  Mailkonto:        ${FIRST_EMAIL} über ${IMAP_HOST} / ${SMTP_HOST}"
echo "  Komponenten:      SOGo, MariaDB, Nginx, Dovecot-Bridge, Postfix-Relay"
echo "  Öffentliche Ports: ausschließlich HTTPS über deinen Reverse Proxy"
echo
read -r -p 'Jetzt installieren? [j/N]: ' CONFIRM
[[ "$CONFIRM" =~ ^[jJyY]$ ]] || die "Abgebrochen."

info "Suche aktuelles Debian-${DEBIAN_VERSION}-Template"
pveam update >/dev/null
TEMPLATE_NAME="$(
  pveam available --section system |
    awk '$2 ~ /^debian-12-standard_.*_amd64\.tar\.(zst|gz)$/ {print $2}' |
    sort -V | tail -n1
)"
[[ -n "$TEMPLATE_NAME" ]] || die "Kein Debian-12-Template gefunden."
TEMPLATE_REF="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}"
if ! pveam list "$TEMPLATE_STORAGE" | awk 'NR>1 {print $1}' | grep -Fxq "$TEMPLATE_REF"; then
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME"
else
  ok "Template bereits vorhanden: ${TEMPLATE_NAME}"
fi

info "Erstelle unprivilegierten LXC ${CTID}"
pct create "$CTID" "$TEMPLATE_REF" \
  --hostname "$FQDN" \
  --ostype debian --arch amd64 --unprivileged 1 \
  --cores "$CORES" --memory "$RAM" --swap "$SWAP" \
  --rootfs "${CT_STORAGE}:${DISK}" \
  --net0 "name=eth0,bridge=${BRIDGE},ip=${IP_CIDR},gw=${GATEWAY},ip6=auto,type=veth" \
  --nameserver "$NAMESERVER" \
  --onboot 1 --start 1
CREATED_CT=1

info "Warte auf Netzwerk und DNS"
READY=0
for _ in $(seq 1 60); do
  if pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1; then READY=1; break; fi
  sleep 2
done
[[ "$READY" -eq 1 ]] || die "Netzwerk/DNS ist im LXC nicht erreichbar."

SHORT_HOST="${FQDN%%.*}"
cat >"$WORKDIR/hosts" <<EOF
127.0.0.1 localhost
${CONTAINER_IP} ${FQDN} ${SHORT_HOST}
EOF
if [[ -n "$AUTHENTIK_INTERNAL_IP" ]]; then
  AUTHENTIK_HOST="${AUTHENTIK_URL#*://}"
  AUTHENTIK_HOST="${AUTHENTIK_HOST%%/*}"
  printf '%s %s\n' "$AUTHENTIK_INTERNAL_IP" "$AUTHENTIK_HOST" >>"$WORKDIR/hosts"
fi
cat >>"$WORKDIR/hosts" <<'EOF'
::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF
pct push "$CTID" "$WORKDIR/hosts" /etc/hosts --perms 0644
pct exec "$CTID" -- touch /etc/.pve-ignore.hosts
printf '%s\n' "$FQDN" >"$WORKDIR/hostname"
pct push "$CTID" "$WORKDIR/hostname" /etc/hostname --perms 0644
pct exec "$CTID" -- hostname "$FQDN"

cat >"$WORKDIR/installer.env" <<EOF
FQDN='${FQDN}'
PUBLIC_URL='${PUBLIC_URL}'
TIMEZONE='${TIMEZONE}'
AUTHENTIK_URL='${AUTHENTIK_URL}'
OIDC_SLUG='${OIDC_SLUG}'
OIDC_CLIENT_ID_B64='$(b64 "$OIDC_CLIENT_ID")'
OIDC_CLIENT_SECRET_B64='$(b64 "$OIDC_CLIENT_SECRET")'
FIRST_EMAIL_B64='$(b64 "$FIRST_EMAIL")'
FIRST_NAME_B64='$(b64 "$FIRST_NAME")'
MAIL_PASSWORD_B64='$(b64 "$MAIL_PASSWORD")'
IMAP_HOST='${IMAP_HOST}'
IMAP_PORT='${IMAP_PORT}'
SMTP_HOST='${SMTP_HOST}'
SMTP_PORT='${SMTP_PORT}'
EOF
chmod 0600 "$WORKDIR/installer.env"
unset OIDC_CLIENT_SECRET MAIL_PASSWORD

info "Lade Container-Installer"
curl -fsSL --retry 3 "$INSTALL_URL" -o "$WORKDIR/groupware-install.sh"
chmod 0700 "$WORKDIR/groupware-install.sh"
bash -n "$WORKDIR/groupware-install.sh"
pct push "$CTID" "$WORKDIR/installer.env" /root/groupware-installer.env --perms 0600
pct push "$CTID" "$WORKDIR/groupware-install.sh" /root/groupware-install.sh --perms 0700

info "Installiere SOGo Groupware im LXC ${CTID}"
pct exec "$CTID" -- bash /root/groupware-install.sh
pct exec "$CTID" -- rm -f /root/groupware-install.sh /root/groupware-installer.env

ok "Installation abgeschlossen."
echo
echo "Öffentliche Adresse: ${PUBLIC_URL}/SOGo/"
echo "Traefik-Ziel:       http://${CONTAINER_IP}:80"
echo "OIDC Redirect URI:  ${PUBLIC_URL}/SOGo/"
echo "Container-Konsole:  pct enter ${CTID}"
echo "Benutzer anlegen:   pct exec ${CTID} -- groupware-user add --email NAME@DOMAIN --name 'Name'"
echo "Healthcheck:        pct exec ${CTID} -- groupware-healthcheck"
echo
echo "Es wurden keine Mailports veröffentlicht und keine DNS-Mailrecords verändert."
