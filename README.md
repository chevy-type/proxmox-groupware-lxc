# Proxmox Groupware LXC

Ein eigenständiger Proxmox-LXC-Installer für eine schlanke SOGo-Groupware:

- SOGo Webmail, Kalender und Kontakte
- Anmeldung über OpenID Connect, insbesondere Authentik
- vorhandene externe Postfächer per IMAP und SMTP
- lokale Dovecot-OIDC-Brücke und senderabhängiger Postfix-Relay
- IONOS als vorkonfigurierter Provider, weitere Provider über eigene Serverdaten

Das Projekt installiert **keinen öffentlichen Mailserver**. Es verändert weder MX/SPF/DKIM/DMARC noch öffnet es Mailports am Router. Öffentlich benötigt wird ausschließlich HTTPS über einen vorhandenen Reverse Proxy.

## Voraussetzungen

- Proxmox VE 8 oder 9
- eine freie statische IPv4-Adresse für den neuen LXC
- ein vorhandener Reverse Proxy, zum Beispiel Traefik
- ein bestehender Authentik-OAuth2/OIDC-Provider
- ein vorhandenes IMAP-/SMTP-Postfach

In Authentik einen **vertraulichen** OAuth2/OIDC-Provider anlegen:

- Redirect URI: `https://DEIN-HOST/SOGo/`
- Scopes: `openid profile email offline_access`
- Der Authentik-Benutzer muss dieselbe E-Mail-Adresse besitzen wie das angebundene Mailkonto.

## Installation

Auf dem Proxmox-Host als `root`:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/chevy-type/proxmox-groupware-lxc/main/ct/groupware.sh)"
```

Der Installer fragt alle nötigen Werte ab, erstellt einen neuen unprivilegierten Debian-12-LXC und richtet den ersten Benutzer ein. Optional kann die interne IP von Traefik beziehungsweise Authentik angegeben werden, damit OIDC-Aufrufe im Heimnetz nicht über die öffentliche Adresse laufen.

Das Reverse-Proxy-Ziel wird am Ende ausgegeben und lautet:

```text
http://LXC-IP:80
```

## Benutzerverwaltung

```bash
pct exec CTID -- groupware-user list
pct exec CTID -- groupware-user add --email user@example.org --name "Vorname Nachname"
pct exec CTID -- groupware-user update --email user@example.org --name "Vorname Nachname"
pct exec CTID -- groupware-user test --email user@example.org
pct exec CTID -- groupware-user disable --email user@example.org
pct exec CTID -- groupware-user enable --email user@example.org
```

Für einen anderen Provider:

```bash
pct exec CTID -- groupware-user add \
  --provider generic \
  --email user@example.org \
  --name "Vorname Nachname" \
  --imap-host imap.example.org --imap-port 993 \
  --smtp-host smtp.example.org --smtp-port 587
```

IMAP wird über SSL/TLS auf Port 993 erwartet, SMTP über STARTTLS auf Port 587.

## Wartung

```bash
pct exec CTID -- groupware-healthcheck
pct exec CTID -- groupware-update
```

`groupware-update` erstellt zuerst eine Konfigurations- und Datenbanksicherung unter `/var/backups/groupware/`.

## SOGo-Pakete

Die frei zugänglichen SOGo-Pakete stammen aus dem offiziellen Nightly-Repository. Der Installer verlangt mindestens SOGo 5.12.9 und hält die installierten SOGo-/SOPE-Pakete nach der Erstinstallation fest, damit ein normales Debian-Update nicht ungeprüft auf einen späteren Nightly-Build wechselt.

## Sicherheit

- Nginx, Dovecot und Postfix lauschen nur innerhalb des Containers beziehungsweise auf Loopback.
- Es werden keine IMAP-/SMTP-Ports am Router freigegeben.
- Externe Mailpasswörter werden mit einem zufälligen AES-Schlüssel verschlüsselt in MariaDB gespeichert.
- Datenbankschlüssel und Zugangsdaten liegen ausschließlich root-lesbar unter `/etc/groupware/`.
- Die Installation verändert keine Mail-DNS-Einträge.

## Status

Version 1.0.0 wurde statisch geprüft (`bash -n`). Ein vollständiger End-to-End-Test muss auf einem frischen Proxmox-LXC mit dem jeweiligen OIDC- und Mailanbieter erfolgen.
