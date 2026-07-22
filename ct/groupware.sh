#!/usr/bin/env bash
# Stable bootstrap for the Proxmox SOGo Groupware LXC installer.
# The immutable 1.0.0 installer is patched with the accumulated compatibility
# fixes before execution.

set -Eeuo pipefail

readonly SCRIPT_VERSION="1.0.5"
readonly CORE_COMMIT="d0198ae10364bc9aadcac1948ca0e2e97d644cf5"
readonly CORE_URL="https://raw.githubusercontent.com/chevy-type/proxmox-groupware-lxc/${CORE_COMMIT}/ct/groupware.sh"
readonly INSTALL_URL_105="https://raw.githubusercontent.com/chevy-type/proxmox-groupware-lxc/main/install/groupware-install-1.0.5.sh"

TMP_CORE="$(mktemp /tmp/groupware-lxc-core.XXXXXX)"
TMP_PATCHED="$(mktemp /tmp/groupware-lxc-patched.XXXXXX)"
cleanup() { rm -f "$TMP_CORE" "$TMP_PATCHED"; }
trap cleanup EXIT

curl -fsSL --retry 3 "$CORE_URL" -o "$TMP_CORE"

awk -v install_url="$INSTALL_URL_105" '
  $0 == "readonly SCRIPT_VERSION=\"1.0.0\"" {
    print "readonly SCRIPT_VERSION=\"1.0.5\""
    next
  }

  $0 ~ /^readonly INSTALL_URL=/ {
    print "readonly INSTALL_URL=\"${INSTALL_URL:-" install_url "}\""
    next
  }

  $0 == "  --ostype debian --arch amd64 --unprivileged 1 \\" {
    print
    print "  --features nesting=1 \\"
    next
  }

  { print }
' "$TMP_CORE" >"$TMP_PATCHED"

chmod 0700 "$TMP_PATCHED"
bash -n "$TMP_PATCHED"
exec bash "$TMP_PATCHED" "$@"
