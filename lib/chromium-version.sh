# Chromium version pin — single source of truth
#
# Bumping Chromium means walking through this list, in this order:
#
#   1. set CHROMIUM_VERSION below (a tag from
#      https://chromiumdash.appspot.com/releases, or any tag present in the
#      chromium-browser-official bucket)
#   2. REPO_DIR=... bash steps/chromium.sh rebase    (re-apply patches, read
#      every .rej it prints — see patches/chromium/README.md)
#   3. bash tests/chromium-ui-font-parse.sh          (parser still sane)
#   4. REPO_DIR=... bash steps/chromium.sh build     (hours)
#   5. REPO_DIR=... bash steps/chromium.sh install verify
#
# Keep the version close to the installed Google Chrome: the Widevine CDM in
# /opt/google/chrome/WidevineCdm declares x-cdm-host-versions "10,11" and the
# browser must implement one of those host versions. A Chromium much newer or
# older than the CDM is the usual cause of "CDM failed to load".
#
# A version file for the *installed* tree is written by the step at
# /usr/lib/chromium/VERSION; it is what makes `install` idempotent.

CHROMIUM_VERSION="157.0.8103.38"

CHROMIUM_TARBALL_URL="https://commondatastorage.googleapis.com/chromium-browser-official/chromium-${CHROMIUM_VERSION}.tar.xz"

# Debian-style install layout: binary + resources in one directory, a thin
# wrapper in /usr/bin, settings in /etc/chromium (see doc/chromium-build.md).
CHROMIUM_INSTALL_DIR="/usr/lib/chromium"
CHROMIUM_WRAPPER_PATH="/usr/bin/chromium"
CHROMIUM_ETC_DIR="/etc/chromium"
CHROMIUM_UI_FONT_CONF="${CHROMIUM_ETC_DIR}/ui-font.conf"

# Build workspace: tarball, unpacked source, out/Default. Reused across runs,
# so an interrupted build resumes instead of starting over (~50 GB).
CHROMIUM_BUILD_ROOT="${CHROMIUM_BUILD_ROOT:-/var/cache/chromium-build}"
