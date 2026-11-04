#!/bin/bash
# steps/pi-path.sh - PI ON PATH (system-wide, permanent)
#
# Makes `pi` runnable from ANY shell (login, non-login, tty console, st/dwm
# terminal) without re-exporting PATH by hand.
#
# The pi installer puts the launcher in $HOME/.pi/agent/bin/pi — it does NOT
# add that directory to any shell profile. bootstrap.sh used to create
# /usr/local/bin/pi -> $NODE_DIR/bin/pi, which dangles as soon as pi upgrades
# itself into its managed install (releases/<version>/), leaving no `pi` on
# PATH in a fresh shell.
#
# What this step does (idempotent):
#   1. Locates the real managed launcher (must not be a dangling symlink).
#   2. Re-points /usr/local/bin/pi at it (system-wide, for non-login shells
#      and for scripts that call /usr/local/bin/pi directly).
#   3. Installs /etc/profile.d/pi.sh so every login shell gets
#      $HOME/.pi/agent/bin on PATH (per-user override wins over the shared
#      symlink).
#   4. Verifies `pi --version` from a clean environment.
#
# The matching per-shell PATH export lives in dotfiles/shell/bashrc
# (deployed by steps/root-dotfiles.sh / steps/user-bashrc.sh).

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

PI_HOME_LAUNCHER="${HOME:-/root}/.pi/agent/bin/pi"
SHARED_LINK="/usr/local/bin/pi"
PROFILE_D="/etc/profile.d/pi.sh"

echo "*****************************************************"
echo "PI ON PATH (permanent)"
echo "*****************************************************"

# ------------------------------------------------------------------
# 1. Locate the real launcher
# ------------------------------------------------------------------
PI_LAUNCHER=""
for candidate in "$PI_HOME_LAUNCHER" /root/.pi/agent/bin/pi; do
    if [ -x "$candidate" ] && [ ! -L "$candidate" ]; then
        PI_LAUNCHER="$candidate"
        break
    fi
    # Accept a symlink only if it resolves to something that exists
    if [ -x "$candidate" ] && [ -e "$(readlink -f "$candidate" 2>/dev/null)" ]; then
        PI_LAUNCHER="$candidate"
        break
    fi
done

if [ -z "$PI_LAUNCHER" ]; then
    echo "ERROR: no pi launcher found (looked for $PI_HOME_LAUNCHER)."
    echo "       Install pi first: REPO_DIR=$REPO_DIR bash steps/pi-clean-reinstall.sh"
    exit 1
fi
echo "  launcher: $PI_LAUNCHER"

# ------------------------------------------------------------------
# 2. Repair the shared /usr/local/bin/pi symlink
# ------------------------------------------------------------------
current_target=""
if [ -L "$SHARED_LINK" ]; then
    current_target="$(readlink "$SHARED_LINK")"
fi

if [ -L "$SHARED_LINK" ] && [ "$(readlink -f "$SHARED_LINK" 2>/dev/null)" = "$(readlink -f "$PI_LAUNCHER" 2>/dev/null)" ]; then
    echo "  $SHARED_LINK already -> $current_target"
elif [ -L "$SHARED_LINK" ] && [ ! -e "$SHARED_LINK" ]; then
    echo "  repairing dangling symlink: $SHARED_LINK -> $current_target"
    ln -sfn "$PI_LAUNCHER" "$SHARED_LINK" || { echo "ERROR: could not create $SHARED_LINK."; exit 1; }
    echo "  $SHARED_LINK -> $PI_LAUNCHER"
elif [ -e "$SHARED_LINK" ] && [ ! -L "$SHARED_LINK" ]; then
    echo "  WARNING: $SHARED_LINK is a real file, leaving it alone."
else
    ln -sfn "$PI_LAUNCHER" "$SHARED_LINK" || { echo "ERROR: could not create $SHARED_LINK."; exit 1; }
    echo "  $SHARED_LINK -> $PI_LAUNCHER"
fi

# ------------------------------------------------------------------
# 3. System-wide PATH for login shells (all users)
# ------------------------------------------------------------------
PROFILE_CONTENT='# pi coding agent — per-user managed launcher (added by steps/pi-path.sh)
# pi installs to $HOME/.pi/agent/bin and does not touch shell profiles itself.
case ":$PATH:" in
    *":$HOME/.pi/agent/bin:"*) ;;
    *) [ -d "$HOME/.pi/agent/bin" ] && PATH="$HOME/.pi/agent/bin:$PATH" && export PATH ;;
esac'

if [ -f "$PROFILE_D" ] && [ "$(cat "$PROFILE_D" 2>/dev/null)" = "$PROFILE_CONTENT" ]; then
    echo "  $PROFILE_D already current"
else
    mkdir -p /etc/profile.d 2>/dev/null || true
    printf '%s\n' "$PROFILE_CONTENT" > "$PROFILE_D" || { echo "ERROR: could not write $PROFILE_D."; exit 1; }
    chmod 644 "$PROFILE_D"
    echo "  $PROFILE_D installed"
fi

# ------------------------------------------------------------------
# 4. Verify from a clean environment (no inherited PATH/pi vars)
# ------------------------------------------------------------------
echo "  verifying from a clean login shell..."
# `type -P` skips the pi() shell function from bashrc and reports the real file.
clean_path="$(env -i HOME="${HOME:-/root}" PATH=/usr/local/bin:/usr/bin:/bin \
    bash -lc 'type -P pi' 2>/dev/null)" || clean_path=""

if [ -n "$clean_path" ]; then
    echo "  pi resolves to a real executable in a clean login shell: $clean_path"
else
    echo "ERROR: pi still not on PATH in a clean login shell."
    exit 1
fi

# Also verify a plain non-login shell (e.g. scripts, cron, ssh command) finds it.
nonlogin_path="$(env -i HOME="${HOME:-/root}" PATH=/usr/local/bin:/usr/bin:/bin \
    bash -c 'type -P pi' 2>/dev/null)" || nonlogin_path=""
if [ -n "$nonlogin_path" ]; then
    echo "  pi also resolves in a non-login shell: $nonlogin_path"
else
    echo "WARNING: pi not found in a non-login shell (PATH-dependent caller)."
fi

pi_version="$(env -i HOME="${HOME:-/root}" PATH=/usr/local/bin:/usr/bin:/bin \
    bash -lc 'pi --version' 2>&1 | tail -1)"
if [ -n "$pi_version" ]; then
    echo "  pi --version: $pi_version"
else
    echo "WARNING: could not read pi version (launcher may still be fine)."
fi

echo "SUCCESS: pi is permanently on PATH."
echo "  shared link:  $SHARED_LINK -> $PI_LAUNCHER"
echo "  login PATH:   $PROFILE_D"
echo "  per-shell:    dotfiles/shell/bashrc (steps/root-dotfiles.sh)"
exit 0
