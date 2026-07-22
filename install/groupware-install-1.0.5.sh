#!/usr/bin/env bash
# Bootstrap for the container-side SOGo Groupware installer.

set -Eeuo pipefail

readonly INSTALLER_VERSION="1.0.5"
readonly REPOSITORY="chevy-type/proxmox-groupware-lxc"
readonly REPOSITORY_REF="${GROUPWARE_REPOSITORY_REF:-main}"
readonly RAW_BASE="https://raw.githubusercontent.com/${REPOSITORY}/${REPOSITORY_REF}/install/parts"

if ! command -v curl >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl
fi

TMP_INSTALLER="$(mktemp /tmp/groupware-container-installer.XXXXXX)"
cleanup() { rm -f "$TMP_INSTALLER"; }
trap cleanup EXIT

for part in \
  00-base.sh \
  10-sogo.sh \
  20-dovecot.sh \
  30-postfix-nginx.sh \
  40-user-cli.sh \
  50-finish.sh
do
  curl -fsSL --retry 3 "${RAW_BASE}/${part}?v=${INSTALLER_VERSION}" >>"$TMP_INSTALLER"
  printf '\n' >>"$TMP_INSTALLER"
done

chmod 0700 "$TMP_INSTALLER"
bash -n "$TMP_INSTALLER"
exec bash "$TMP_INSTALLER"
