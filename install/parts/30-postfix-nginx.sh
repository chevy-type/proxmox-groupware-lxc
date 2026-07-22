smtp_sasl_auth_enable = yes
smtp_sasl_password_maps = mysql:/etc/postfix/mysql/sasl-password.cf
smtp_sasl_security_options = noanonymous
smtp_sasl_tls_security_options = noanonymous
smtp_sasl_mechanism_filter = plain, login
smtp_tls_security_level = encrypt
smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt
smtp_connection_cache_on_demand = no

message_size_limit = 52428800
mailbox_size_limit = 0
biff = no
append_dot_mydomain = no
readme_directory = no
EOF

cat >/etc/postfix/master.cf <<'EOF'
127.0.0.1:submission inet n       -       n       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_sasl_type=dovecot
  -o smtpd_sasl_path=private/dovecot-auth
  -o smtpd_sasl_security_options=noanonymous
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject
  -o smtpd_relay_restrictions=permit_sasl_authenticated,reject
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
  -o smtpd_sender_restrictions=reject_sender_login_mismatch
pickup    unix  n       -       n       60      1       pickup
cleanup   unix  n       -       n       -       0       cleanup
qmgr      unix  n       -       n       300     1       qmgr
tlsmgr    unix  -       -       n       1000?   1       tlsmgr
rewrite   unix  -       -       n       -       -       trivial-rewrite
bounce    unix  -       -       n       -       0       bounce
defer     unix  -       -       n       -       0       bounce
trace     unix  -       -       n       -       0       bounce
verify    unix  -       -       n       -       1       verify
flush     unix  n       -       n       1000?   0       flush
proxymap  unix  -       -       n       -       -       proxymap
proxywrite unix -       -       n       -       1       proxymap
smtp      unix  -       -       n       -       -       smtp
relay     unix  -       -       n       -       -       smtp
showq     unix  n       -       n       -       -       showq
error     unix  -       -       n       -       -       error
retry     unix  -       -       n       -       -       error
discard   unix  -       -       n       -       -       discard
local     unix  -       n       n       -       -       local
virtual   unix  -       n       n       -       -       virtual
lmtp      unix  -       -       n       -       -       lmtp
anvil     unix  -       -       n       -       1       anvil
scache    unix  -       -       n       -       1       scache
postlog   unix-dgram n  -       n       -       1       postlogd
EOF

log "Konfiguriere Nginx für SOGo"
rm -f /etc/nginx/sites-enabled/default
cat >/etc/nginx/sites-available/groupware <<EOF
server {
  listen 80 default_server;
  listen [::]:80 default_server;
  server_name ${FQDN};
  client_max_body_size 50m;

  location = / {
    return 302 /SOGo/;
  }

  location = /.well-known/caldav {
    return 301 /SOGo/dav/;
  }
  location = /.well-known/carddav {
    return 301 /SOGo/dav/;
  }

  location ^~ /SOGo.woa/WebServerResources/ {
    alias /usr/lib/GNUstep/SOGo/WebServerResources/;
    expires 30d;
    access_log off;
  }
  location ^~ /SOGo/WebServerResources/ {
    alias /usr/lib/GNUstep/SOGo/WebServerResources/;
    expires 30d;
    access_log off;
  }

  location /SOGo {
    proxy_pass http://127.0.0.1:20000;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header x-webobjects-server-name \$host;
    proxy_set_header x-webobjects-server-port 443;
    proxy_set_header x-webobjects-server-url https://\$host;
    proxy_set_header x-webobjects-server-protocol HTTP/1.0;
    proxy_set_header Connection "";
    proxy_buffering off;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
  }
}
EOF
