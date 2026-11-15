#!/bin/bash
# steps/slskd.sh - SOULSEEK DAEMON (slskd), PER LOGIN SESSION
#
# What this installs:
#   /opt/slskd/slskd            standalone linux-x64 binary (glibc build)
#   /etc/slskd/slskd.yml        system-wide TEMPLATE (credentials, ports, library)
#   /var/lib/slskd/music        shared library, group `slskd`, world-readable
#   /var/lib/slskd/downloads    shared download dir, group `slskd`, setgid 2775
#   /usr/local/bin/slsk         per-user control script (start/stop/status/…)
#
# What it REMOVES (all of it was a boot service, which was the problem):
#   /etc/rc.d/rc.slskd                   the rc script itself
#   the `/etc/rc.d/rc.slskd start` line  from /etc/rc.d/rc.local
#   /etc/sudoers.d/slskd                 the %wheel rule for the rc script
#
# WHY (decided 2026-11-15): slskd used to run as the system user `slskd`,
# started from rc.local at boot. That meant it was running at the login prompt,
# survived every logout and every user change, and could only be controlled
# through `sudo /etc/rc.d/rc.slskd` — which rs (not in wheel) could not use at
# all. Now it is a SESSION daemon: scripts/dwm-start.sh starts `slsk start`
# inside the login session, dwm-start's EXIT trap and `session-stop` stop it,
# and KillUserProcesses=yes is the backstop. Any user (root, rs, …) starts and
# stops their own instance with no sudo; the process never outlives the login.
#
# Idempotent: the binary is only downloaded when missing (or with
# --force-download), the config template is only rewritten when it differs, and
# the retired pieces are only touched when they are present.

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "SOULSEEK DAEMON (slskd, per session)"
echo "*****************************************************"

ok=true

# --- Keys (if available) ---
# post-install-global exports setup.keys.root before calling this step; when it
# is run directly, load the same file so the credentials are not lost.
if [ -z "${SLSKD_USERNAME:-}" ] && declare -F read_setup_keys >/dev/null 2>&1 \
   && [ -f "$REPO_DIR/setup.keys.root" ]; then
    read_setup_keys
fi

SLSKD_VERSION="${SLSKD_VERSION:-0.25.1}"
SLSKD_USERNAME="${SLSKD_USERNAME:-}"
SLSKD_PASSWORD="${SLSKD_PASSWORD:-}"
SLSKD_WEB_PORT="${SLSKD_WEB_PORT:-5030}"
SLSKD_SLSK_PORT="${SLSKD_SLSK_PORT:-50300}"
SLSKD_SHARE_DIR="${SLSKD_SHARE_DIR:-/var/lib/slskd/music}"
SLSKD_DOWNLOAD_DIR="${SLSKD_DOWNLOAD_DIR:-/var/lib/slskd/downloads}"

# --- Shared library group (not a login user; nothing runs as it) ---
echo "Ensuring the shared library group 'slskd'..."
if getent group slskd >/dev/null 2>&1; then
    echo "  group slskd already exists"
else
    groupadd -r slskd >/dev/null 2>&1 && echo "  created group slskd" || {
        echo "ERROR: could not create group slskd"
        ok=false
    }
fi

# --- Directories ---
if $ok; then
    echo "Creating slskd directories..."
    mkdir -p /opt/slskd /etc/slskd "$SLSKD_SHARE_DIR" "$SLSKD_DOWNLOAD_DIR" || {
        echo "ERROR: Failed to create slskd directories."
        ok=false
    }
fi

if $ok; then
    # The library is read by every user; the download dir must be WRITABLE by
    # whichever user's session is downloading. Setgid so files created by one
    # user stay accessible to the other.
    chgrp slskd "$SLSKD_SHARE_DIR" "$SLSKD_DOWNLOAD_DIR" 2>/dev/null || true
    chmod 0755 "$SLSKD_SHARE_DIR" 2>/dev/null || true
    chmod 2775 "$SLSKD_DOWNLOAD_DIR" 2>/dev/null || true
    echo "  $SLSKD_SHARE_DIR    0755 root:slskd"
    echo "  $SLSKD_DOWNLOAD_DIR 2775 root:slskd (setgid)"
fi

# Any human user must be in the `slskd` group to download into that directory.
# Group changes apply to the NEXT login (a running session keeps its old list).
if $ok; then
    for u in $(awk -F: '$3 >= 1000 && $3 < 65534 { print $1 }' /etc/passwd 2>/dev/null); do
        if id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qx slskd; then
            echo "  $u is already in group slskd"
        elif usermod -aG slskd "$u" 2>/dev/null; then
            echo "  added $u to group slskd (takes effect at the next login)"
        else
            echo "  WARNING: could not add $u to group slskd"
        fi
    done
fi

# --- Download and extract standalone linux-x64 zip ---
if $ok; then
    SLSKD_ZIP="slskd-${SLSKD_VERSION}-linux-x64.zip"
    SLSKD_URL="https://github.com/slskd/slskd/releases/download/${SLSKD_VERSION}/${SLSKD_ZIP}"

    if [ ! -f "/opt/slskd/slskd" ] || [ "$1" = "--force-download" ]; then
        echo "Downloading slskd v${SLSKD_VERSION} (standalone linux-x64)..."
        if ! curl -fsSL -o "/tmp/${SLSKD_ZIP}" "$SLSKD_URL"; then
            echo "ERROR: Failed to download slskd from $SLSKD_URL"
            ok=false
        fi

        if $ok; then
            echo "Extracting slskd to /opt/slskd..."
            if ! unzip -o "/tmp/${SLSKD_ZIP}" -d /opt/slskd; then
                echo "ERROR: Failed to extract slskd zip."
                ok=false
            fi
            rm -f "/tmp/${SLSKD_ZIP}"
        fi
    else
        echo "slskd already present in /opt/slskd (use --force-download to re-download)."
    fi
    chmod 0755 /opt/slskd/slskd 2>/dev/null || true
fi

# --- Config TEMPLATE (copied per user on first 'slsk start') ---
if $ok; then
    echo "Writing the slskd config template to /etc/slskd/slskd.yml..."
    NEW_CONFIG=$(mktemp)
    # The heredoc below is deliberately UNQUOTED so the SLSKD_* values are
    # filled in. Two traps that have already bitten:
    #   * a backtick in it is executed by bash *while the step runs* (an old
    #     'slsk start' once got executed and printed its output into the file);
    #   * a dollar-brace expansion that is not one of the placeholders is a
    #     "bad substitution" and aborts the whole heredoc.
    # Keep command words in plain quotes, never in backticks.
    cat > "$NEW_CONFIG" << SLSKDEOF
# slskd configuration TEMPLATE (generated by slackware-installer-for-rs)
#
# This file is NOT used directly by a running slskd. 'slsk start' copies it to
# the user's own app dir on first use:
#   root -> /root/.local/share/slskd/slskd.yml
#   rs   -> /home/rs/.local/share/slskd/slskd.yml
# and runs from that copy, so each user can change settings in the web UI
# without owning /etc. Edit THIS file to change the defaults for a fresh copy;
# 'slsk reset-config' drops a user's copy so the next start picks it up again.
#
# Web UI: http://<host>:${SLSKD_WEB_PORT}
# Soulseek protocol port: ${SLSKD_SLSK_PORT}
#
# slskd runs as the logged-in user, only while that session exists
# (scripts/dwm-start.sh starts it, session-stop/logout stops it).

soulseek:
  username: ${SLSKD_USERNAME}
  password: ${SLSKD_PASSWORD}

shares:
  directories:
    - ${SLSKD_SHARE_DIR}

directories:
  downloads: ${SLSKD_DOWNLOAD_DIR}

web:
  port: ${SLSKD_WEB_PORT}
  https:
    disabled: true
  authentication:
    disabled: true

soulseek_port: ${SLSKD_SLSK_PORT}
SLSKDEOF
    if [ -s "$NEW_CONFIG" ] && ! cmp -s "$NEW_CONFIG" /etc/slskd/slskd.yml 2>/dev/null; then
        install -Dm 0644 "$NEW_CONFIG" /etc/slskd/slskd.yml && echo "  wrote /etc/slskd/slskd.yml"
    else
        echo "  /etc/slskd/slskd.yml already up to date"
    fi
    rm -f "$NEW_CONFIG"
fi

# --- Control script (per user, no sudo) ---
if $ok; then
    echo "Installing /usr/local/bin/slsk (per-session control)..."
    SRC="$REPO_DIR/scripts/slsk.sh"
    if [ ! -f "$SRC" ]; then
        echo "ERROR: $SRC missing."
        ok=false
    elif [ -f /usr/local/bin/slsk ] && cmp -s "$SRC" /usr/local/bin/slsk; then
        echo "  /usr/local/bin/slsk already up to date"
    else
        install -Dm 0755 "$SRC" /usr/local/bin/slsk && echo "  installed /usr/local/bin/slsk"
    fi
fi

# --- Retire the boot service ---
# The rc script, its rc.local line and its sudoers rule all exist to run slskd
# as a system user at boot. All three are removed: the daemon is session-scoped
# now, and `slsk` needs no privileges at all.
echo "Retiring the boot-service pieces..."
if [ -f /etc/rc.d/rc.slskd ]; then
    rm -f /etc/rc.d/rc.slskd && echo "  removed /etc/rc.d/rc.slskd"
else
    echo "  /etc/rc.d/rc.slskd: already gone"
fi

if [ -f /etc/rc.d/rc.local ] && grep -q 'rc\.slskd' /etc/rc.d/rc.local 2>/dev/null; then
    RCL_TMP=$(mktemp /etc/rc.d/.rc.local.XXXXXX) || RCL_TMP=""
    if [ -n "$RCL_TMP" ]; then
        RCL_MODE=$(stat -c %a /etc/rc.d/rc.local 2>/dev/null || echo 755)
        grep -v 'rc\.slskd' /etc/rc.d/rc.local > "$RCL_TMP"
        chmod "$RCL_MODE" "$RCL_TMP" 2>/dev/null || chmod 755 "$RCL_TMP"
        chown root:root "$RCL_TMP" 2>/dev/null || true
        mv "$RCL_TMP" /etc/rc.d/rc.local
        echo "  removed the rc.slskd start line from /etc/rc.d/rc.local"
    fi
fi
# rc.M only runs rc.local `if [ -x ]` — the powerkey-hold step rewrites this
# file too, so never let the mode drift away from executable.
[ -f /etc/rc.d/rc.local ] && chmod 755 /etc/rc.d/rc.local

if [ -f /etc/sudoers.d/slskd ]; then
    rm -f /etc/sudoers.d/slskd && echo "  removed /etc/sudoers.d/slskd (no root access needed any more)"
else
    echo "  /etc/sudoers.d/slskd: already gone"
fi

# A leftover instance of the OLD system service would still hold the ports.
legacy=$(pgrep -u slskd -x slskd 2>/dev/null | head -1)
if [ -n "$legacy" ]; then
    echo "  NOTE: a legacy system slskd is still running (pid $legacy, user slskd)."
    echo "        It holds port ${SLSKD_WEB_PORT} until it is stopped; reboot after"
    echo "        this install and it will not come back."
fi

if $ok; then
    echo "SUCCESS: slskd v${SLSKD_VERSION} installed as a per-session daemon."
    echo ""
    echo "  Binary:      /opt/slskd/slskd"
    echo "  Template:    /etc/slskd/slskd.yml   (copied per user on first start)"
    echo "  Library:     $SLSKD_SHARE_DIR (0755, group slskd)"
    echo "  Downloads:   $SLSKD_DOWNLOAD_DIR (2775 setgid, group slskd)"
    echo "  Control:     slsk start|stop|restart|status|log|reset-config — no sudo"
    echo "  Per-user:    ~/.local/share/slskd (config + database), log /var/log/<user>-slskd.log"
    echo "  Web UI:      http://localhost:${SLSKD_WEB_PORT}"
    echo ""
    echo "  It starts with the dwm session and stops with it (logout / user change)."
    echo "  IMPORTANT: set the Soulseek username/password in /etc/slskd/slskd.yml."
    echo "  An existing per-user copy keeps its own settings — 'slsk reset-config'"
    echo "  drops it so the template is used again."
    exit 0
else
    echo "ERROR: slskd setup encountered errors."
    exit 1
fi
