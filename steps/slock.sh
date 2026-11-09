#!/bin/bash
# steps/slock.sh - SCREEN LOCKER (custom PAM slock from sources/slock)
#
# This repo carries its own slock: a minimal X11 locker (sources/slock/slock.c)
# that maps a fullscreen override-redirect window, grabs keyboard + pointer and
# authenticates through PAM (service name "slock"). Colour feedback:
#   olive = idle, green = typing, yellow = checking, red = wrong password.
#
# History worth knowing: commit e6d7a55 "no lock" removed the old physlock
# setup, and steps/screen-locking.sh used to `rm -f /usr/local/bin/slock` as
# part of that cleanup. This step puts slock back and screen-locking.sh now
# leaves it alone. Lid close suspends and locks first — see steps/screen-locking.sh
# and doc/screen-locking.md.
#
# Bound to Mod+Escape in dotfiles/suckless/dwm/config.h.
#
# Caveat on THIS machine: display commits can stall (doc/display-freeze.md), and
# slock ignores SIGINT/SIGTERM on purpose. If the screen wedges while locked,
# Ctrl+Alt+F2 (X handles VT switches itself) gets you a console; from there
# `pkill -9 slock` or restart X. SSH from another box works too.
#
# Idempotent: rebuilds only when the source changed, reinstalls only when the
# binary differs, and the PAM file is rewritten only when it differs.

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "SLOCK (PAM screen locker)"
echo "*****************************************************"

ok=true
SRC="$REPO_DIR/sources/slock"
BUILD="${SLOCK_BUILD_DIR:-/var/cache/slock-build}"
DEST="/usr/local/bin/slock"
PAM_DEST="/etc/pam.d/slock"

[ -d "$SRC" ] || { echo "ERROR: $SRC missing"; exit 1; }

# 1. Build out of tree so the repo (and its committed slock/slock.o) stay clean.
mkdir -p "$BUILD"
cp -a "$SRC"/. "$BUILD"/
rm -f "$BUILD/slock" "$BUILD/slock.o"
if make -s -C "$BUILD" clean >/dev/null 2>&1; then :; fi
if ! make -C "$BUILD"; then
    echo "ERROR: build failed"
    exit 1
fi
[ -x "$BUILD/slock" ] || { echo "ERROR: $BUILD/slock not produced"; exit 1; }

# 2. Shared libraries must all resolve (a missing libpam/libX11 = silent fail
#    at lock time, i.e. a locker that cannot lock).
if ldd "$BUILD/slock" 2>/dev/null | grep -q 'not found'; then
    echo "ERROR: unresolved shared libraries:"
    ldd "$BUILD/slock" | grep 'not found' | sed 's/^/  /'
    exit 1
fi
echo "  built: $BUILD/slock ($(du -h "$BUILD/slock" | cut -f1)), all libraries resolve"

# 3. Install binary + PAM service.
if [ -f "$DEST" ] && cmp -s "$BUILD/slock" "$DEST"; then
    echo "  $DEST already up to date"
else
    install -Dm 755 "$BUILD/slock" "$DEST" && echo "  installed $DEST"
fi
if [ -f "$PAM_DEST" ] && cmp -s "$SRC/slock.pam" "$PAM_DEST"; then
    echo "  $PAM_DEST already up to date"
else
    install -Dm 644 "$SRC/slock.pam" "$PAM_DEST" && echo "  installed $PAM_DEST"
fi

# 4. Prove the PAM stack is usable, end to end, without touching any password:
#    a deliberately wrong password must come back as PAM_AUTH_ERR. Anything else
#    (PAM_SERVICE_ERR / PAM_SYSTEM_ERR) means the stack itself is broken and
#    slock would be un-unlockable.
cat > "$BUILD/pamcheck.c" <<'CEOF'
#include <security/pam_appl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static int conv(int n, const struct pam_message **m, struct pam_response **r, void *d) {
    (void)m; (void)d;
    struct pam_response *resp = calloc(n, sizeof(*resp));
    for (int i = 0; i < n; i++) resp[i].resp = strdup("definitely-not-the-password");
    *r = resp;
    return PAM_SUCCESS;
}
int main(void) {
    struct pam_conv c = { conv, NULL };
    pam_handle_t *ph = NULL;
    int rc = pam_start("slock", "root", &c, &ph);
    if (rc != PAM_SUCCESS) { printf("PAM_START_ERR %d\n", rc); return 1; }
    rc = pam_authenticate(ph, 0);
    pam_end(ph, rc);
    printf("%d\n", rc);
    return 0;
}
CEOF
if command -v gcc >/dev/null 2>&1 && gcc -O0 -o "$BUILD/pamcheck" "$BUILD/pamcheck.c" -lpam 2>/dev/null; then
    rc=$("$BUILD/pamcheck" 2>/dev/null)
    case "$rc" in
        7) echo "  PAM stack OK: wrong password rejected with PAM_AUTH_ERR (7)" ;;
        *) echo "  ERROR: PAM returned '$rc' for a wrong password (expected 7 = PAM_AUTH_ERR)"
           echo "         slock would not be able to authenticate — check $PAM_DEST and /etc/pam.d/other"
           ok=false ;;
    esac
else
    echo "  WARNING: could not build the PAM checker (skipping the PAM test)"
fi

# 5. xidle — idle time, needed to lock BEFORE the screen blanks.
#    (Nothing in the base system reports idle time; see sources/xidle/xidle.c.)
XIDLE_SRC="$REPO_DIR/sources/xidle/xidle.c"
XIDLE_DEST="/usr/local/bin/xidle"
if [ -f "$XIDLE_SRC" ]; then
    if gcc -O2 -Wall -o "$BUILD/xidle" "$XIDLE_SRC" -lXss -lX11 2>/dev/null \
       || gcc -O2 -Wall -o "$BUILD/xidle" "$XIDLE_SRC" $(pkg-config --cflags --libs xscrnsaver 2>/dev/null); then
        if [ -f "$XIDLE_DEST" ] && cmp -s "$BUILD/xidle" "$XIDLE_DEST"; then
            echo "  $XIDLE_DEST already up to date"
        else
            install -Dm 755 "$BUILD/xidle" "$XIDLE_DEST" && echo "  installed $XIDLE_DEST"
        fi
    else
        echo "  ERROR: could not build xidle (libXss headers missing?) — idle lock will not work"
        ok=false
    fi
else
    echo "  WARNING: $XIDLE_SRC missing — idle lock will not work"
fi

# 6. Session helpers: lock-screen.sh (lock + wait until covered) and
#    idle-lock.sh (lock just before the panel blanks).
for helper in lock-screen.sh idle-lock.sh; do
    src="$REPO_DIR/scripts/$helper"
    dst="/usr/local/bin/$helper"
    if [ ! -f "$src" ]; then
        echo "  WARNING: $src missing"
        continue
    fi
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
        echo "  $dst already up to date"
    else
        install -Dm 755 "$src" "$dst" && echo "  installed $dst"
    fi
done

# 7. Report the pieces the session needs.
echo "  binary : $DEST ($(stat -c %a "$DEST" 2>/dev/null))"
echo "  pam    : $PAM_DEST"
echo "  helpers: /usr/local/bin/lock-screen.sh, /usr/local/bin/idle-lock.sh, /usr/local/bin/xidle"
echo "  marker : /run/slock.locked is written by slock only after the grabs succeed"
if [ -d /usr/local/src/suckless/dwm-stamp ]; then
    if grep -q 'slock' "$REPO_DIR/dotfiles/suckless/dwm/config.h" 2>/dev/null; then
        echo "  dwm key: Mod+Escape -> slock (see dotfiles/suckless/dwm/config.h)"
    fi
fi
echo "  note   : slock ignores SIGINT/SIGTERM; recover with Ctrl+Alt+F2 + 'pkill -9 slock'"

if $ok; then
    echo "SUCCESS: slock installed; PAM stack accepts the service and rejects a wrong password."
    exit 0
else
    echo "ERROR: slock installed but not usable (see messages above)."
    exit 1
fi
