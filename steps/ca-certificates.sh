#!/bin/bash
# steps/ca-certificates.sh - CA CERTIFICATES (PACKAGING)

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "PACKAGING AND RELATED SECURITY (CA Certificates)"
echo "*****************************************************"

echo "Installing ca-certificates for HTTPS/git etc...."
if ! install_pkg "ca-certificates"; then
    echo "ERROR: could not install ca-certificates. HTTPS, git, and package verification may be affected."
    exit 1
fi
update-ca-certificates --fresh 2>/dev/null || true
echo "SUCCESS: ca-certificates installed and CA trust store updated."
exit 0
