log "Konfiguriere SOGo"
install -d -o root -g sogo -m 0750 /etc/sogo
python3 - "$FQDN" "$PUBLIC_URL" "$MAIL_DOMAIN" "$DB_USER" "$DB_PASSWORD" "$OIDC_DISCOVERY_URL" "$OIDC_CLIENT_ID" "$OIDC_CLIENT_SECRET" "$TIMEZONE" "${AES_KEY_HEX:0:32}" <<'PY'
from pathlib import Path
import sys

(
    fqdn, public_url, mail_domain, db_user, db_password,
    discovery_url, client_id, client_secret, timezone, sogo_secret,
) = sys.argv[1:]

def q(value: str) -> str:
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'

db = f"mysql://{db_user}:{db_password}@127.0.0.1:3306/groupware"
text = f'''{{
  WOWorkersCount = 4;
  WOListenQueueSize = 20;
  WOWatchDogRequestTimeout = 10;
  SxVMemLimit = 512;

  SOGoPageTitle = "Groupware";
  SOGoLanguage = German;
  SOGoTimeZone = {q(timezone)};
  SOGoAppointmentSendEMailNotifications = YES;
  SOGoACLsSendEMailNotifications = YES;
  SOGoFoldersSendEMailNotifications = YES;
  SOGoLoginModule = Mail;
  SOGoVacationEnabled = NO;
  SOGoForwardEnabled = NO;
  SOGoSieveScriptsEnabled = NO;
  SOGoMailAuxiliaryUserAccountsEnabled = YES;
  SOGoCreateIdentitiesDisabled = NO;
  SOGoSecretType = plain;
  SOGoSecretValue = {q(sogo_secret)};
  SOGoEnablePublicAccess = NO;

  OCSFolderInfoURL = {q(db + "/sogo_folder_info")};
  OCSSessionsFolderURL = {q(db + "/sogo_sessions_folder")};
  SOGoProfileURL = {q(db + "/sogo_user_profile")};
  OCSStoreURL = {q(db + "/sogo_store")};
  OCSAclURL = {q(db + "/sogo_acl")};
  OCSCacheFolderURL = {q(db + "/sogo_cache_folder")};
  OCSOpenIdURL = {q(db + "/sogo_openid")};

  SOGoUserSources = (
    {{
      type = sql;
      id = users;
      viewURL = {q(db + "/users")};
      canAuthenticate = YES;
      isAddressBook = YES;
      userPasswordAlgorithm = md5;
    }}
  );

  SOGoAuthenticationType = openid;
  SOGoXSRFValidationEnabled = NO;
  SOGoOpenIdConfigUrl = {q(discovery_url)};
  SOGoOpenIdClient = {q(client_id)};
  SOGoOpenIdClientSecret = {q(client_secret)};
  SOGoOpenIdScope = "openid profile email offline_access";
  SOGoOpenIdEmailParam = email;
  SOGoOpenIdEnableRefreshToken = YES;
  SOGoOpenIdTokenCheckInterval = 300;
  SOGoOpenIdLogoutEnabled = YES;

  SOGoMailDomain = {q(mail_domain)};
  SOGoIMAPServer = "imap://127.0.0.1:143";
  SOGoSMTPServer = "smtp://127.0.0.1:587";
  SOGoMailingMechanism = smtp;
  SOGoForceExternalLoginWithEmail = YES;
  SOGoMailShowSubscribedFoldersOnly = NO;
  NGImap4AuthMechanism = xoauth2;
  NGImap4DisableIMAP4Pooling = YES;
  SOGoSMTPAuthenticationType = xoauth2;

  SOGoMemcachedHost = "127.0.0.1";
  SOGoZipPath = "/usr/bin/zip";
  SOGoSoftQuotaRatio = 0.9;
  SOGoMaximumFailedLoginCount = 0;
  SOGoMaximumMessageSizeLimit = 0;
}}
'''
Path('/etc/sogo/sogo.conf').write_text(text)
PY
chown root:sogo /etc/sogo/sogo.conf
chmod 0640 /etc/sogo/sogo.conf

# A package-created per-user defaults file has precedence over /etc/sogo/sogo.conf.
# Preserve it for reference but keep the generated installer configuration authoritative.
if [[ -f /var/lib/sogo/GNUstep/Defaults/.GNUstepDefaults ]]; then
  mv /var/lib/sogo/GNUstep/Defaults/.GNUstepDefaults \
    /var/lib/sogo/GNUstep/Defaults/.GNUstepDefaults.package-backup
fi

cat >/etc/default/sogo <<'EOF'
PREFORK=4
EOF

log "Konfiguriere Dovecot als lokale OIDC-zu-IMAP-Brücke"
OIDC_CLIENT_ID_URL="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$OIDC_CLIENT_ID")"