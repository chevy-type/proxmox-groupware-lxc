cat >/usr/local/sbin/groupware-healthcheck <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
for service in mariadb memcached dovecot postfix sogo nginx; do
  systemctl is-active --quiet "\$service" || { echo "FEHLER: \$service ist nicht aktiv" >&2; exit 1; }
done
curl -fsS --max-time 10 '${OIDC_DISCOVERY_URL}' >/dev/null
curl -fsS --max-time 10 -H 'Host: ${FQDN}' http://127.0.0.1/SOGo/ >/dev/null
mariadb --batch --skip-column-names '${DB_NAME}' -e 'SELECT COUNT(*) FROM mail_accounts;' >/dev/null
printf 'OK: Groupware, OIDC, Datenbank und lokale Dienste sind erreichbar.\n'
EOF
chmod 0755 /usr/local/sbin/groupware-healthcheck

cat >/usr/local/sbin/groupware-update <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/var/backups/groupware/${STAMP}"
install -d -m 0700 "$BACKUP"
cp -a /etc/sogo /etc/dovecot /etc/postfix /etc/nginx/sites-available/groupware /etc/groupware "$BACKUP/"
mariadb-dump --single-transaction groupware | gzip -9 >"$BACKUP/groupware.sql.gz"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y full-upgrade
systemctl restart mariadb memcached dovecot postfix sogo nginx
sleep 5
groupware-healthcheck
echo "Backup: $BACKUP"
EOF
chmod 0750 /usr/local/sbin/groupware-update
ln -sfn /usr/local/sbin/groupware-update /usr/local/sbin/update

log "Lege den ersten Benutzer an"
PASSWORD_FILE="$(mktemp)"
chmod 0600 "$PASSWORD_FILE"
printf '%s' "$MAIL_PASSWORD" >"$PASSWORD_FILE"
/usr/local/sbin/groupware-user add \
  --email "$FIRST_EMAIL" \
  --name "$FIRST_NAME" \
  --provider ionos \
  --imap-host "$IMAP_HOST" --imap-port "$IMAP_PORT" \
  --smtp-host "$SMTP_HOST" --smtp-port "$SMTP_PORT" \
  --password-file "$PASSWORD_FILE"
rm -f "$PASSWORD_FILE"
unset MAIL_PASSWORD

log "Prüfe Konfigurationen"
doveconf -n >/dev/null
postfix check
nginx -t

log "Starte Groupware-Dienste"
systemctl restart mariadb memcached dovecot postfix sogo nginx
sleep 8

log "Teste externes IONOS-Konto"
/usr/local/sbin/groupware-user test --email "$FIRST_EMAIL"

log "Führe abschließenden Healthcheck aus"
/usr/local/sbin/groupware-healthcheck

cat >/root/GROUPWARE-INFO.txt <<EOF
Groupware LXC ${INSTALLER_VERSION}
===============================

Weboberfläche: ${PUBLIC_URL}/SOGo/
OIDC Discovery: ${OIDC_DISCOVERY_URL}
OIDC Redirect URI: ${PUBLIC_URL}/SOGo/
Lokaler HTTP-Backend-Port: 80

Benutzer verwalten:
  groupware-user list
  groupware-user add --email user@example.org --name "Vorname Nachname"
  groupware-user update --email user@example.org --name "Vorname Nachname"
  groupware-user test --email user@example.org
  groupware-user disable --email user@example.org

Update mit Sicherung:
  groupware-update

Diagnose:
  groupware-healthcheck
  journalctl -u sogo -u dovecot -u postfix -u nginx --no-pager -n 200

Wichtig:
- Dieser Container ist kein öffentlicher Mailserver.
- Nur HTTP-Port 80 muss intern für den Reverse Proxy erreichbar sein.
- Keine Mailports in der FritzBox weiterleiten.
- Externe Mailpasswörter sind verschlüsselt in MariaDB gespeichert.
- Der notwendige Schlüssel liegt nur root-lesbar unter /etc/groupware/config.json.
EOF
chmod 0600 /root/GROUPWARE-INFO.txt

# Secrets aus der einmaligen Übergabedatei entfernen.
shred -u "$ENV_FILE" 2>/dev/null || rm -f "$ENV_FILE"

ok "Groupware wurde vollständig installiert."
printf '\nWeboberfläche: %s/SOGo/\n' "$PUBLIC_URL"
printf 'Reverse-Proxy-Ziel: http://%s:80\n' "$(hostname -I | awk '{print $1}')"
printf 'Erster Benutzer: %s\n' "$FIRST_EMAIL"
printf 'Info: /root/GROUPWARE-INFO.txt\n'
