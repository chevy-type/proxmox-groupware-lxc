OIDC_CLIENT_SECRET_URL="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$OIDC_CLIENT_SECRET")"

cat >/etc/dovecot/dovecot-oauth2.conf.ext <<EOF
introspection_url = https://${OIDC_CLIENT_ID_URL}:${OIDC_CLIENT_SECRET_URL}@${OIDC_INTROSPECTION_URL#https://}
introspection_mode = post
force_introspection = yes
active_attribute = active
active_value = true
username_attribute = email
tls_ca_cert_file = /etc/ssl/certs/ca-certificates.crt
EOF
chown root:dovecot /etc/dovecot/dovecot-oauth2.conf.ext
chmod 0640 /etc/dovecot/dovecot-oauth2.conf.ext

cat >/etc/dovecot/dovecot-sql.conf.ext <<EOF
driver = mysql
connect = host=127.0.0.1 dbname=${DB_NAME} user=${DB_USER} password=${DB_PASSWORD}
default_pass_scheme = PLAIN
user_query = SELECT 2000 AS uid, 2000 AS gid, CONCAT('/var/lib/groupware/mail/', REPLACE(email, '@', '/')) AS home, 'imapc:~/imapc' AS mail, imap_host AS imapc_host, imap_port AS imapc_port, 'imaps' AS imapc_ssl, imap_user AS imapc_user, CONVERT(AES_DECRYPT(imap_password, UNHEX('${AES_KEY_HEX}')) USING utf8mb4) AS imapc_password FROM mail_accounts WHERE email = LOWER('%u') AND enabled = 1
iterate_query = SELECT email AS username FROM mail_accounts WHERE enabled = 1
EOF
chown root:dovecot /etc/dovecot/dovecot-sql.conf.ext
chmod 0640 /etc/dovecot/dovecot-sql.conf.ext

cp -a /etc/dovecot/dovecot.conf "/etc/dovecot/dovecot.conf.dist.$(date +%s)" 2>/dev/null || true
cat >/etc/dovecot/dovecot.conf <<'EOF'
protocols = imap
listen = 127.0.0.1
base_dir = /run/dovecot
state_dir = /var/lib/dovecot
instance_name = groupware

ssl = no
disable_plaintext_auth = no
auth_mechanisms = xoauth2 oauthbearer
auth_username_format = %Lu
auth_verbose = yes

mail_uid = 2000
mail_gid = 2000
mail_home = /var/lib/groupware/mail/%d/%n
imapc_features = delay-login
imapc_cmd_timeout = 60s
imapc_connection_retry_count = 3
imapc_connection_retry_interval = 2s
imapc_max_idle_time = 5m
imapc_ssl_verify = yes

passdb {
  driver = oauth2
  mechanisms = xoauth2 oauthbearer
  args = /etc/dovecot/dovecot-oauth2.conf.ext
}

userdb {
  driver = sql
  args = /etc/dovecot/dovecot-sql.conf.ext
}

service imap-login {
  inet_listener imap {
    address = 127.0.0.1
    port = 143
  }
  inet_listener imaps {
    port = 0
  }
}

service auth {
  unix_listener /var/spool/postfix/private/dovecot-auth {
    mode = 0660
    user = postfix
    group = postfix
  }
}

protocol imap {
  mail_max_userip_connections = 20
}
EOF

log "Konfiguriere Postfix als ausschließlich lokalen SMTP-Relay"
install -d -o root -g postfix -m 0750 /etc/postfix/mysql

cat >/etc/postfix/mysql/sender-relay.cf <<EOF
user = ${DB_USER}
password = ${DB_PASSWORD}
hosts = 127.0.0.1
dbname = ${DB_NAME}
query = SELECT CONCAT('[', smtp_host, ']:', smtp_port) FROM mail_accounts WHERE email = LOWER('%s') AND enabled = 1
EOF
cat >/etc/postfix/mysql/sasl-password.cf <<EOF
user = ${DB_USER}
password = ${DB_PASSWORD}
hosts = 127.0.0.1
dbname = ${DB_NAME}
query = SELECT CONCAT(smtp_user, ':', CONVERT(AES_DECRYPT(smtp_password, UNHEX('${AES_KEY_HEX}')) USING utf8mb4)) FROM mail_accounts WHERE email = LOWER('%s') AND enabled = 1
EOF
cat >/etc/postfix/mysql/sender-login.cf <<EOF
user = ${DB_USER}
password = ${DB_PASSWORD}
hosts = 127.0.0.1
dbname = ${DB_NAME}
query = SELECT email FROM mail_accounts WHERE email = LOWER('%s') AND enabled = 1
EOF
chown root:postfix /etc/postfix/mysql/*.cf
chmod 0640 /etc/postfix/mysql/*.cf

cat >/etc/postfix/main.cf <<EOF
compatibility_level = 3.6
myhostname = ${FQDN}
myorigin = \$myhostname
mydestination = localhost
inet_interfaces = loopback-only
inet_protocols = ipv4
mynetworks = 127.0.0.0/8
relay_domains =
local_recipient_maps =

smtpd_banner = \$myhostname ESMTP
smtpd_sasl_type = dovecot
smtpd_sasl_path = private/dovecot-auth
smtpd_sasl_auth_enable = yes
smtpd_sasl_security_options = noanonymous
smtpd_sender_login_maps = mysql:/etc/postfix/mysql/sender-login.cf
smtpd_relay_restrictions = permit_sasl_authenticated,reject
smtpd_recipient_restrictions = permit_sasl_authenticated,reject
smtpd_sender_restrictions = reject_sender_login_mismatch

smtp_sender_dependent_authentication = yes
sender_dependent_relayhost_maps = mysql:/etc/postfix/mysql/sender-relay.cf
