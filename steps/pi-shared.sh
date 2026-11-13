#!/bin/bash
# steps/pi-shared.sh - SYSTEM-WIDE PI LAUNCHER (usable by every user)
#
# The pi installer puts everything under $HOME: the launcher in
# ~/.pi/agent/bin/pi and the actual program in ~/.pi/agent/install/releases/<v>.
# For root that lives inside /root, which no other user may even traverse, so
# /usr/local/bin/pi -> /root/.pi/agent/bin/pi worked only for root.
#
# This step publishes a read-only copy of the managed install at
# /opt/pi-agent and points the shared /usr/local/bin/pi at it:
#
#   /usr/local/bin/pi -> /opt/pi-agent/bin/pi -> /opt/pi-agent/install/...
#
# Per-user config still comes from each user's own ~/.pi/agent
# (settings.json / auth.json / extensions — see steps/user-pi-agent.sh).
# Root keeps preferring ~/.pi/agent/bin (dotfiles/shell/bashrc prepends it), so
# root's self-updating managed install is untouched.
#
# Idempotent: re-copies only when the managed version or launcher changed.
# Run again after a pi self-update to publish the new version to other users.

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

SRC="${PI_SRC:-/root/.pi/agent}"
DEST="${PI_SHARED_DEST:-/opt/pi-agent}"
LINK=/usr/local/bin/pi
TARGET_USER="${TARGET_USER:-}"

echo "*****************************************************"
echo "PI: SYSTEM-WIDE LAUNCHER"
echo "*****************************************************"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: pi-shared.sh must run as root"
    exit 1
fi

VERSION_FILE="$SRC/install/current-version"
if [ ! -r "$VERSION_FILE" ]; then
    echo "ERROR: no managed pi install at $SRC (missing install/current-version)."
    echo "       Install it first: REPO_DIR=$REPO_DIR bash steps/pi-clean-reinstall.sh"
    exit 1
fi
VERSION="$(cat "$VERSION_FILE")"
RELEASE_DIR="$SRC/install/releases/$VERSION"
if [ ! -d "$RELEASE_DIR" ]; then
    echo "ERROR: managed release directory missing: $RELEASE_DIR"
    exit 1
fi
echo "  source : $SRC (version $VERSION)"

install -d -m 0755 "$DEST" "$DEST/bin" "$DEST/install" "$DEST/install/releases"

# ── launcher (+ helper tools it ships: fd, rg) ─────────────────────────
for f in "$SRC"/bin/*; do
    [ -e "$f" ] || continue
    name=$(basename "$f")
    if [ -f "$DEST/bin/$name" ] && cmp -s "$f" "$DEST/bin/$name"; then
        :
    else
        cp -a "$f" "$DEST/bin/$name"
        chmod 0755 "$DEST/bin/$name"
        echo "  installed $DEST/bin/$name"
    fi
done

# ── install metadata ──────────────────────────────────────────────────
for f in current-version managed-install.json; do
    [ -f "$SRC/install/$f" ] || continue
    if [ -f "$DEST/install/$f" ] && cmp -s "$SRC/install/$f" "$DEST/install/$f"; then
        :
    else
        cp -a "$SRC/install/$f" "$DEST/install/$f"
        echo "  installed $DEST/install/$f"
    fi
done

# ── the release tree for the current version ──────────────────────────
if [ -f "$DEST/install/releases/$VERSION/.pi-shared-complete" ]; then
    echo "  release $VERSION already published"
else
    echo "  copying release $VERSION ($(du -sh "$RELEASE_DIR" | cut -f1))..."
    rm -rf "$DEST/install/releases/$VERSION"
    cp -a "$RELEASE_DIR" "$DEST/install/releases/$VERSION"
    # The managed install is 0700 (root-only). Every user must be able to
    # read/execute the program but not write it: software installation is
    # still root's job.
    chmod -R a+rX "$DEST"
    touch "$DEST/install/releases/$VERSION/.pi-shared-complete"
    echo "  published $DEST/install/releases/$VERSION"
fi

# ── shared symlink ────────────────────────────────────────────────────
if [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$DEST/bin/pi" ]; then
    echo "  $LINK already -> $DEST/bin/pi"
else
    ln -sfn "$DEST/bin/pi" "$LINK"
    echo "  $LINK -> $DEST/bin/pi"
fi

# ── verify as root and, when given, as the target user ────────────────
verify_as() {
    user="$1"
    if [ "$user" = root ]; then
        out=$(env -i HOME=/root PATH=/usr/local/bin:/usr/bin:/bin /usr/local/bin/pi --version 2>&1 | tail -1)
    else
        out=$(su - "$user" -c 'env PATH=/usr/local/bin:/usr/bin:/bin /usr/local/bin/pi --version' 2>&1 | tail -1)
    fi
    case "$out" in
        *[0-9].[0-9]*) echo "  pi --version as $user: $out" ;;
        *) echo "ERROR: pi does not run as $user: $out" ; return 1 ;;
    esac
}

ok=true
verify_as root || ok=false
if [ -n "$TARGET_USER" ] && id "$TARGET_USER" >/dev/null 2>&1; then
    verify_as "$TARGET_USER" || ok=false
fi

if $ok; then
    echo "SUCCESS: pi is runnable by every user from /usr/local/bin/pi (v$VERSION)."
    exit 0
fi
echo "ERROR: shared pi launcher is not usable (see above)."
exit 1
