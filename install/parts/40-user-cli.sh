ln -sfn /etc/nginx/sites-available/groupware /etc/nginx/sites-enabled/groupware
nginx -t

log "Installiere Verwaltungs- und Diagnosebefehle"
cat >/usr/local/sbin/groupware-user <<'PY'
#!/usr/bin/env python3
import argparse
import getpass
import imaplib
import json
import smtplib
import ssl
import sys
from pathlib import Path

import pymysql

CONFIG_PATH = Path('/etc/groupware/config.json')
PROVIDERS = {
    'ionos': {
        'imap_host': 'imap.ionos.de', 'imap_port': 993,
        'smtp_host': 'smtp.ionos.de', 'smtp_port': 587,
    },
    'generic': {},
}

def load_config():
    return json.loads(CONFIG_PATH.read_text())

def db_connect(cfg):
    db = cfg['database']
    return pymysql.connect(
        host=db['host'], user=db['user'], password=db['password'],
        database=db['name'], charset='utf8mb4', autocommit=True,
        cursorclass=pymysql.cursors.DictCursor,
    )

def read_secret(path, prompt):
    if path:
        return Path(path).read_text().rstrip('\r\n')
    return getpass.getpass(prompt)

def normalize_email(value):
    value = value.strip().lower()
    if '@' not in value or value.startswith('@') or value.endswith('@'):
        raise SystemExit('Ungültige E-Mail-Adresse.')
    return value

def add_or_update(args):
    cfg = load_config()
    email = normalize_email(args.email)
    provider = PROVIDERS.get(args.provider, {})
    imap_host = args.imap_host or provider.get('imap_host') or cfg['defaults']['imap_host']
    imap_port = args.imap_port or provider.get('imap_port') or cfg['defaults']['imap_port']
    smtp_host = args.smtp_host or provider.get('smtp_host') or cfg['defaults']['smtp_host']
    smtp_port = args.smtp_port or provider.get('smtp_port') or cfg['defaults']['smtp_port']
    imap_user = args.imap_user or email
    smtp_user = args.smtp_user or email

    if args.password_file:
        shared_password = read_secret(args.password_file, 'Mailpasswort: ')
    elif not args.imap_password_file and not args.smtp_password_file:
        shared_password = read_secret(None, 'Mailpasswort für IMAP und SMTP: ')
    else:
        shared_password = None
    imap_password = read_secret(args.imap_password_file, 'IMAP-Passwort: ') if args.imap_password_file else (shared_password or read_secret(None, 'IMAP-Passwort: '))
    smtp_password = read_secret(args.smtp_password_file, 'SMTP-Passwort: ') if args.smtp_password_file else (shared_password or read_secret(None, 'SMTP-Passwort: '))
    if not imap_password or not smtp_password:
        raise SystemExit('Passwort darf nicht leer sein.')

    key = cfg['aes_key_hex']
    with db_connect(cfg) as db, db.cursor() as cur:
        cur.execute(
            """INSERT INTO users (c_uid,c_name,c_password,c_cn,mail)
               VALUES (%s,%s,NULL,%s,%s)
               ON DUPLICATE KEY UPDATE c_name=VALUES(c_name),c_cn=VALUES(c_cn),mail=VALUES(mail)""",
            (email, email, args.name, email),
        )
        cur.execute(
            """INSERT INTO mail_accounts
               (email,imap_host,imap_port,imap_user,imap_password,smtp_host,smtp_port,smtp_user,smtp_password,enabled)
               VALUES (%s,%s,%s,%s,AES_ENCRYPT(%s,UNHEX(%s)),%s,%s,%s,AES_ENCRYPT(%s,UNHEX(%s)),1)
               ON DUPLICATE KEY UPDATE
                 imap_host=VALUES(imap_host), imap_port=VALUES(imap_port), imap_user=VALUES(imap_user),
                 imap_password=VALUES(imap_password), smtp_host=VALUES(smtp_host), smtp_port=VALUES(smtp_port),
                 smtp_user=VALUES(smtp_user), smtp_password=VALUES(smtp_password), enabled=1""",
            (email, imap_host, imap_port, imap_user, imap_password, key,
             smtp_host, smtp_port, smtp_user, smtp_password, key),
        )
    print(f'OK: {email} wurde eingerichtet.')

def list_users(_args):
    cfg = load_config()
    with db_connect(cfg) as db, db.cursor() as cur:
        cur.execute("""SELECT u.mail,u.c_cn,a.imap_host,a.smtp_host,a.enabled
                       FROM users u LEFT JOIN mail_accounts a ON a.email=u.mail ORDER BY u.mail""")
        rows = cur.fetchall()
    if not rows:
        print('Keine Benutzer vorhanden.')
        return
    for row in rows:
        state = 'aktiv' if row['enabled'] else 'deaktiviert'
        print(f"{row['mail']}\t{row['c_cn']}\t{row['imap_host']}\t{row['smtp_host']}\t{state}")

def set_enabled(args, enabled):
    cfg = load_config()
    email = normalize_email(args.email)
    with db_connect(cfg) as db, db.cursor() as cur:
        cur.execute('UPDATE mail_accounts SET enabled=%s WHERE email=%s', (1 if enabled else 0, email))
        if cur.rowcount != 1:
            raise SystemExit('Benutzer nicht gefunden.')
    print(f"OK: {email} ist {'aktiv' if enabled else 'deaktiviert'}.")

def remove_user(args):
    cfg = load_config()
    email = normalize_email(args.email)
    if not args.yes:
        answer = input(f'Mail-Zugang für {email} entfernen? Kalender/Kontakte bleiben in SOGo erhalten. [j/N]: ')
        if answer.lower() not in ('j', 'y'):
            raise SystemExit('Abgebrochen.')
    with db_connect(cfg) as db, db.cursor() as cur:
        cur.execute('DELETE FROM mail_accounts WHERE email=%s', (email,))
        cur.execute('DELETE FROM users WHERE mail=%s', (email,))
    print(f'OK: {email} wurde aus der Benutzerzuordnung entfernt.')

def fetch_account(email):
    cfg = load_config()
    key = cfg['aes_key_hex']
    with db_connect(cfg) as db, db.cursor() as cur:
        cur.execute(
            """SELECT email,imap_host,imap_port,imap_user,
                      CONVERT(AES_DECRYPT(imap_password,UNHEX(%s)) USING utf8mb4) AS imap_password,
                      smtp_host,smtp_port,smtp_user,
                      CONVERT(AES_DECRYPT(smtp_password,UNHEX(%s)) USING utf8mb4) AS smtp_password
               FROM mail_accounts WHERE email=%s AND enabled=1""",
            (key, key, normalize_email(email)),
        )
        row = cur.fetchone()
    if not row:
        raise SystemExit('Aktiver Benutzer nicht gefunden.')
    return row

def test_account(args):
    account = fetch_account(args.email)
    context = ssl.create_default_context()
    print(f"IMAP {account['imap_host']}:{account['imap_port']} ...", end=' ', flush=True)
    with imaplib.IMAP4_SSL(account['imap_host'], int(account['imap_port']), ssl_context=context, timeout=15) as imap:
        imap.login(account['imap_user'], account['imap_password'])
        status, folders = imap.list()
        if status != 'OK':
            raise RuntimeError('Ordnerliste konnte nicht geladen werden.')
        imap.logout()
    print(f'OK ({len(folders or [])} Ordner)')

    print(f"SMTP {account['smtp_host']}:{account['smtp_port']} ...", end=' ', flush=True)
    with smtplib.SMTP(account['smtp_host'], int(account['smtp_port']), timeout=15) as smtp:
        smtp.ehlo()
        smtp.starttls(context=context)
        smtp.ehlo()
        smtp.login(account['smtp_user'], account['smtp_password'])
    print('OK')

def build_parser():
    parser = argparse.ArgumentParser(description='Benutzer externer Mailkonten für SOGo verwalten')
    sub = parser.add_subparsers(dest='command', required=True)

    for command in ('add', 'update'):
        p = sub.add_parser(command)
        p.add_argument('--email', required=True)
        p.add_argument('--name', required=True)
        p.add_argument('--provider', default='ionos', choices=sorted(PROVIDERS))
        p.add_argument('--imap-host')
        p.add_argument('--imap-port', type=int)
        p.add_argument('--imap-user')
        p.add_argument('--smtp-host')
        p.add_argument('--smtp-port', type=int)
        p.add_argument('--smtp-user')
        p.add_argument('--password-file')
        p.add_argument('--imap-password-file')
        p.add_argument('--smtp-password-file')
        p.set_defaults(func=add_or_update)

    p = sub.add_parser('list')
    p.set_defaults(func=list_users)
    p = sub.add_parser('test')
    p.add_argument('--email', required=True)
    p.set_defaults(func=test_account)
    p = sub.add_parser('disable')
    p.add_argument('--email', required=True)
    p.set_defaults(func=lambda a: set_enabled(a, False))
    p = sub.add_parser('enable')
    p.add_argument('--email', required=True)
    p.set_defaults(func=lambda a: set_enabled(a, True))
    p = sub.add_parser('remove')
    p.add_argument('--email', required=True)
    p.add_argument('--yes', action='store_true')
    p.set_defaults(func=remove_user)
    return parser

def main():
    args = build_parser().parse_args()
    try:
        args.func(args)
    except (imaplib.IMAP4.error, smtplib.SMTPException, OSError, pymysql.MySQLError) as exc:
        print(f'FEHLER: {exc}', file=sys.stderr)
        raise SystemExit(1)

if __name__ == '__main__':
    main()
PY
chmod 0750 /usr/local/sbin/groupware-user
