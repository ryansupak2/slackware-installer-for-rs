#!/bin/bash
# steps/kernel-7.4.sh - BUILD + INSTALL THE 7.4 KERNEL AS A SECOND BOOT ENTRY
#
# Why: the display freeze (doc/display-freeze.md) is fixed upstream by
# cbe5654759, which only exists from 7.4 on. Backporting it into 7.2.15 was
# tried and REGRESSED X start (the machine froze with no kernel message at all),
# because the commit needs its whole series around it. So the fix is taken where
# it lives: a 7.4 kernel, installed as an ADDITIONAL elilo entry. The existing
# 7.2.15 entry stays on disk and stays bootable - that is the rollback.
#
# This kernel is kept entirely separate from the distro one:
#   * CONFIG_LOCALVERSION="-wcl"  -> release 7.4.0-rc2-wcl
#   * /lib/modules/7.4.0-rc2-wcl  -> never touches /lib/modules/7.2.15
#   * /boot/efi/EFI/Slackware/vmlinuz-74rc2 + its own elilo image block
# A `slackpkg upgrade kernel-generic` cannot collide with it either.
#
# No initrd: CONFIG_BLK_DEV_NVME=y and CONFIG_EXT4_FS=y in this config, so the
# root device is available before any module is loaded. The step checks that
# after olddefconfig and refuses to install a boot entry that needs an initrd it
# does not have.
#
# Usage (default action: status):
#   REPO_DIR=$PWD bash steps/kernel-7.4.sh fetch
#   REPO_DIR=$PWD bash steps/kernel-7.4.sh build
#   REPO_DIR=$PWD bash steps/kernel-7.4.sh install     # makes it the DEFAULT
#   REPO_DIR=$PWD bash steps/kernel-7.4.sh status
#
# Nothing here reboots.

set -u

REPO_DIR="${REPO_DIR:-/root/Development/slackware-installer-for-rs}"
KVER_SRC="7.4-rc2"
KREL_LOCAL="-wcl"
WORK="${KERNEL_WORK:-/var/cache/kernel-build}"
TARBALL="${WORK}/linux-${KVER_SRC}.tar.gz"
# git.kernel.org's /t/ short link 301-redirects to the snapshot URL below;
# cdn.kernel.org does not carry RCs, so this is the canonical place for one.
SRC_URL="https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/snapshot/linux-${KVER_SRC}.tar.gz"
BASE_CONFIG="/boot/config-7.2.15.x64"
SRC_DIR="${WORK}/linux-7.4.0-rc2"          # tarball top dir (auto-detected below)
# git.kernel.org snapshots unpack to linux-7.4-rc2 (no ".0"); accept either.
if [ ! -d "$SRC_DIR" ] && [ -d "${WORK}/linux-${KVER_SRC}" ]; then
    SRC_DIR="${WORK}/linux-${KVER_SRC}"
fi
ELILO="/boot/efi/EFI/Slackware/elilo.conf"
BOOT_DEST="/boot/efi/EFI/Slackware"
NEW_LABEL="vmlinuz-74rc2"
OLD_LABEL="vmlinuz"
# Boot params for the NEW entry: the distro set, minus every xe.* knob (7.4 has
# the complete PSR series, so PSR2/selective fetch can be left at defaults).
NEW_APPEND="root=/dev/nvme0n1p3 vga=normal ro pcie_aspm=off iwlwifi.power_save=0 i915.fastboot=1 i915.enable_psr=0"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

ACTION="${1:-status}"
echo "*****************************************************"
echo "KERNEL 7.4 ($KVER_SRC) — $ACTION"
echo "*****************************************************"
ok=true
note() { echo "  $*"; }

kernelrelease() { make -s -C "$SRC_DIR" kernelrelease 2>/dev/null | tail -1; }

# ---------------------------------------------------------------------------
do_fetch() {
    mkdir -p "$WORK"
    if [ -f "$TARBALL" ] && [ "$(stat -c %s "$TARBALL")" -gt 1000000 ]; then
        note "tarball present: $TARBALL ($(du -h "$TARBALL" | cut -f1))"
    else
        note "downloading $SRC_URL"
        # git.kernel.org publishes no sha256 for tag tarballs; the transport is
        # TLS to kernel.org and the tag is verifiable in the tree's Makefile.
        curl -fL# -o "${TARBALL}.part" "$SRC_URL" || { note "ERROR: download failed"; ok=false; return; }
        mv "${TARBALL}.part" "$TARBALL"
        note "downloaded $(du -h "$TARBALL" | cut -f1)"
    fi

    if [ -d "$SRC_DIR" ]; then
        note "source tree present: $SRC_DIR"
    else
        note "extracting…"
        tar -xf "$TARBALL" -C "$WORK" || { note "ERROR: extract failed"; ok=false; return; }
        # the archive's top directory name is not guaranteed; find it
        d=$(tar -tf "$TARBALL" 2>/dev/null | head -1 | cut -d/ -f1)
        [ -n "$d" ] && [ -d "${WORK}/${d}" ] || { note "ERROR: unexpected archive layout"; ok=false; return; }
        if [ "${WORK}/${d}" != "$SRC_DIR" ]; then
            note "note: top dir is '$d' (expected '$(basename "$SRC_DIR")')"
            SRC_DIR="${WORK}/${d}"
        fi
    fi
    note "version in tree: $(grep -E '^(VERSION|PATCHLEVEL|SUBLEVEL|EXTRAVERSION) =' "$SRC_DIR/Makefile" | tr '\n' ' ')"
}

# ---------------------------------------------------------------------------
do_build() {
    [ -d "$SRC_DIR" ] || { note "ERROR: run 'fetch' first"; ok=false; return; }
    cd "$SRC_DIR" || { ok=false; return; }

    # 1. Config: the running distro config, adapted to 7.4, with a localversion
    #    so release + module tree stay separate from the packaged kernel.
    if [ ! -f .config ]; then
        cp "$BASE_CONFIG" .config
        note "config seeded from $BASE_CONFIG"
    fi
    sed -i 's|^CONFIG_LOCALVERSION=.*|CONFIG_LOCALVERSION="'"$KREL_LOCAL"'"|' .config
    note "running olddefconfig (7.4 has new symbols; defaults are taken)"
    make -s olddefconfig

    # 2. Storage must be built in, or this entry needs an initrd we do not make.
    local nvme ext4
    nvme=$(grep -E '^CONFIG_BLK_DEV_NVME=' .config)
    ext4=$(grep -E '^CONFIG_EXT4_FS=' .config)
    note "storage: $nvme / $ext4"
    case "$nvme" in *=y) ;; *) note "ERROR: NVMe is not built in — this entry would need an initrd"; ok=false; return ;; esac
    case "$ext4" in *=y) ;; *) note "ERROR: ext4 is not built in — this entry would need an initrd"; ok=false; return ;; esac

    local rel
    rel=$(kernelrelease)
    note "kernelrelease: $rel"

    # 3. Build. bzImage + modules; this is the long part.
    note "building bzImage + modules with -j$(nproc) (this is the long part)"
    make -j"$(nproc)" bzImage modules || { note "ERROR: build failed"; ok=false; return; }

    [ -f arch/x86/boot/bzImage ] || { note "ERROR: no bzImage"; ok=false; return; }
    note "built: arch/x86/boot/bzImage ($(du -h arch/x86/boot/bzImage | cut -f1))"

    # 4. The whole point: the PSR selective-fetch series must be in this tree.
    if grep -q 'skip_su_area_calc' drivers/gpu/drm/i915/display/intel_psr.c; then
        note "fix present: cbe5654759 markers (skip_su_area_calc) in intel_psr.c"
    else
        note "WARNING: cbe5654759 markers not found — the freeze fix is NOT in this tree"
        ok=false
    fi
}

# ---------------------------------------------------------------------------
do_install() {
    [ -f "$SRC_DIR/arch/x86/boot/bzImage" ] || { note "ERROR: run 'build' first"; ok=false; return; }
    cd "$SRC_DIR" || { ok=false; return; }

    local rel
    rel=$(kernelrelease)
    [ -n "$rel" ] || { note "ERROR: cannot determine kernelrelease"; ok=false; return; }
    case "$rel" in *7.4*) ;; *) note "ERROR: unexpected release '$rel'"; ok=false; return ;; esac

    # 1. Modules into their own tree (never touches 7.2.15).
    note "installing modules -> /lib/modules/$rel"
    make -s modules_install || { note "ERROR: modules_install failed"; ok=false; return; }
    [ -f "/lib/modules/$rel/kernel/drivers/gpu/drm/xe/xe.ko" ] \
        && note "xe.ko installed in the new tree" \
        || { note "ERROR: xe.ko missing from /lib/modules/$rel"; ok=false; return; }
    depmod "$rel" && note "depmod done"

    # 2. Kernel image next to the distro one.
    install -m 644 arch/x86/boot/bzImage "$BOOT_DEST/vmlinuz-74rc2" \
        && note "installed $BOOT_DEST/vmlinuz-74rc2"

    # 3. elilo: add (or refresh) the entry and make it the DEFAULT. The old
    #    entry stays, reachable from the menu — that is the rollback.
    cp -a "$ELILO" "$ELILO.bak-$(date +%Y%m%d-%H%M%S)"
    python3 - "$ELILO" "$NEW_LABEL" "$NEW_APPEND" "$OLD_LABEL" <<'PYEOF'
import re, sys
path, label, append, old = sys.argv[1:5]
text = open(path).read()
lines = text.splitlines()

block = ['image=vmlinuz-74rc2',
         '\tlabel=%s' % label,
         '\tread-only',
         '\tappend="%s"' % append]

# drop any previous block with this label (image= line + until next image=/EOF)
out, i = [], 0
while i < len(lines):
    if lines[i].strip() == 'image=vmlinuz-74rc2':
        i += 1
        while i < len(lines) and not lines[i].strip().startswith('image='):
            i += 1
        continue
    out.append(lines[i]); i += 1
lines = out

# default= must name our new label; the old entry is still selectable
if any(l.strip().startswith('default=') for l in lines):
    lines = [('default=%s' % label) if l.strip().startswith('default=') else l for l in lines]
else:
    # put it next to the other loader settings at the top
    insert_at = 0
    for n, l in enumerate(lines):
        if l.strip().startswith(('chooser=', 'delay=', 'timeout=', 'default=')):
            insert_at = n + 1
    lines.insert(insert_at, 'default=%s' % label)

# a menu that can actually be used: delay/timeout in the loader header
def bump(prefix, value):
    global lines
    if any(l.strip().startswith(prefix) for l in lines):
        lines = [(prefix + value) if l.strip().startswith(prefix) else l for l in lines]
    return lines
bump('delay=', '5')
bump('timeout=', '50')

open(path, 'w').write('\n'.join(lines + block) + '\n')
PYEOF
    note "elilo: entry '$NEW_LABEL' added as default; '$OLD_LABEL' kept as fallback"

    # 4. Read it back — never trust the edit.
    echo "  --- $ELILO ---"
    sed 's/^/    /' "$ELILO"
    if ! grep -q "^default=$NEW_LABEL" "$ELILO"; then
        note "ERROR: default= did not take"; ok=false
    fi
    if ! grep -q "label=$OLD_LABEL\$" "$ELILO"; then
        note "ERROR: the old entry is gone — rollback would be impossible"; ok=false
    fi
    if [ -x /sbin/lilo ]; then lilo -q >/dev/null 2>&1 || true; fi
}


# ---------------------------------------------------------------------------
# BOOT MENU: arrow keys, no typing, newest kernel by default.
#
# elilo facts that matter here:
#   * a chooser is only drawn in INTERACTIVE mode -> `prompt` is required;
#   * delay/timeout are TENTHS of a second (timeout=150 == 15 s).
#
# chooser=textmenu draws a real menu (cursor keys + Enter) and needs a message
# file with dialog geometry: two 0x01 markers around the menu area and two 0x02
# markers around the prompt field. elilo ships one; we reword its prose in place
# so every control byte and line width survives. If that cannot be done safely,
# the step falls back to chooser=simple with a plain-text message, which always
# renders (you would then type the label only to pick the older kernel).
do_bootmenu() {
    [ -f "$ELILO" ] || { note "ERROR: $ELILO not found"; ok=false; return; }
    cp -a "$ELILO" "$ELILO.bak-$(date +%Y%m%d-%H%M%S)"

    python3 - "$ELILO" "$BOOT_DEST" "$NEW_LABEL" <<'PYEOF'
import os, sys
conf_path, bootdir, newlabel = sys.argv[1:4]
msg_path = os.path.join(bootdir, 'elilo.msg')
ex = '/usr/doc/elilo-3.16/examples/textmenu_chooser/textmenu-message.msg'

def pad(old, new):
    new = new[:len(old)]
    return new + b' ' * (len(old) - len(new))

pairs = [
 (b"Install and Recovery Disk", b"Slackware - kernel choice"),
 (b"This CD demonstrates the elilo textmenu chooser.",
  b"Newest kernel boots by default; older is below."),
 (b"from the menu with the curosr keys, enter exptra parameters at the propmt,",
  b"Pick with the Up/Down arrow keys, then press Enter to boot that kernel."),
 (b"and press <return> to start the process.  Help can be made available via",
  b"Enter alone (or waiting 15 seconds) boots the default. No typing needed."),
 (b"the function keys.  On a serial console, use Ctrl-F followed by the",
  b"To change the default later, edit 'default=' in elilo.conf."),
 (b"relevant function key number.", b" "),
 (b"Beware that this is an install disk, and misuse can result in the loss of",
  b"vmlinuz-74rc2 = 7.4.0-rc2-wcl  newest, display fix, DEFAULT"),
 (b"any data currently on your disks.",
  b"vmlinuz = 7.2.15 known-good  "),
 # the original sentence continues onto the same line; blank the leftover
 (b"You can select an entry", b"                        "),
 # F1/F2 help pages are not configured in this elilo.conf, so blank that line
 # (the F1/F2 glyphs sit between attribute runs, so they are plain ASCII)
 (b"Help: [", b"       "),
 (b"F1", b"  "),
 (b"-General]  [", b"             "),
 (b"F2", b"  "),
 (b"-Params]", b"         "),
]

textmenu_ok = False
if os.path.exists(ex):
    data = open(ex, 'rb').read()
    okall = True
    for old, new in pairs:
        if data.count(old) != 1:
            print("  (skipping span, count %d: %r)" % (data.count(old), old))
            continue
        data = data.replace(old, pad(old, new))
    if okall and data.count(b'\x01') == 2 and data.count(b'\x02') == 2:
        open(msg_path, 'wb').write(data)
        textmenu_ok = True
        plain = bytes(b for b in data if b == 10 or 32 <= b < 127).decode()
        print("  message file: %s (%d bytes, geometry intact)" % (msg_path, len(data)))
        print("  --- screen (elilo fills in the menu between these lines) ---")
        for line in plain.splitlines():
            if line.strip():
                print("    " + line.rstrip())
if not textmenu_ok:
    open(msg_path, 'w').write(
        "  +--------------------------------------------------------------+\n"
        "  |  Slackware - kernel choice                                   |\n"
        "  |    vmlinuz-74rc2   7.4.0-rc2-wcl  newest (DEFAULT)            |\n"
        "  |    vmlinuz         7.2.15         fallback                    |\n"
        "  |  Type a label + Enter. Enter alone boots the default in 15 s. |\n"
        "  +--------------------------------------------------------------+\n")
    print("  message file: %s (plain fallback)" % msg_path)

lines = [l.rstrip('\n') for l in open(conf_path)]
def set_or_insert(prefix, value):
    global lines
    if any(l.strip().startswith(prefix) for l in lines):
        lines = [(value if l.strip().startswith(prefix) else l) for l in lines]
    else:
        idx = next((i for i, l in enumerate(lines) if l.strip().startswith('image=')), len(lines))
        lines.insert(idx, value)

lines = [l for l in lines if l.strip() != 'prompt']
set_or_insert('chooser=', 'chooser=%s' % ('textmenu' if textmenu_ok else 'simple'))
set_or_insert('message=', 'message=elilo.msg')
set_or_insert('timeout=', 'timeout=150')
set_or_insert('delay=', 'delay=5')
set_or_insert('default=', 'default=%s' % newlabel)
idx = next((i for i, l in enumerate(lines) if l.strip().startswith('image=')), len(lines))
lines.insert(idx, 'prompt')

out, i = [], 0
while i < len(lines):
    out.append(lines[i])
    if lines[i].strip().startswith('image='):
        img = lines[i].split('=', 1)[1].strip()
        j, block = i + 1, []
        while j < len(lines) and not lines[j].strip().startswith('image='):
            block.append(lines[j]); j += 1
        desc = ('"7.4.0-rc2-wcl - newest, display fix"' if img == 'vmlinuz-74rc2'
                else '"7.2.15 - known-good fallback"')
        block = [b for b in block if not b.strip().startswith('description=')]
        block.insert(1, '\tdescription=%s' % desc)
        out.extend(block); i = j; continue
    i += 1
open(conf_path, 'w').write('\n'.join(out).rstrip() + '\n')
print("  chooser: %s" % ('textmenu (arrow keys, no typing)' if textmenu_ok else 'simple (type a label)'))
PYEOF

    echo "  --- $ELILO ---"
    sed 's/^/    /' "$ELILO"
    grep -q '^prompt' "$ELILO" || { note "ERROR: prompt missing"; ok=false; }
    [ -f "$BOOT_DEST/elilo.msg" ] || { note "ERROR: message file missing"; ok=false; }
}


# ---------------------------------------------------------------------------
# Per-entry display knobs for the 7.4 kernel, and the default entry.
#
# Measured 2026-11-09: booting 7.4 the first time got through the kernel and the
# root mount, printed console text, then stalled at DRM init — xe is a module
# (CONFIG_DRM_XE=m), so that point is udev loading xe.ko. Same class of display
# hang as doc/display-freeze.md, so the same ladder applies, one rung per boot:
#
#   display psr1   # keep panel self-refresh, drop PSR2 / sel-fetch / panel replay
#   display off    # PSR fully off (next rung if psr1 still stalls)
#   display stock  # back to kernel defaults
#
# Only the vmlinuz-74rc2 entry is touched; the 7.2.15 entry keeps its own set.
MANAGED_RE='^xe\.(enable_psr|enable_psr2_sel_fetch|enable_panel_replay|psr_safest_params|enable_fbc|enable_dsb|enable_dpt|enable_ips)='

strip_xe() {
    local out="" w
    for w in $1; do
        [[ $w =~ $MANAGED_RE ]] && continue
        out="${out:+$out }$w"
    done
    printf '%s' "$out"
}

do_display() {
    local profile="${2:-psr1}" tokens
    case "$profile" in
        psr1)  tokens="xe.enable_dsb=0 xe.enable_psr=1 xe.enable_psr2_sel_fetch=0 xe.enable_panel_replay=0" ;;
        off)   tokens="xe.enable_dsb=0 xe.enable_psr=0 xe.enable_psr2_sel_fetch=0 xe.enable_panel_replay=0" ;;
        stock) tokens="" ;;
        *) note "ERROR: unknown profile '$profile' (psr1|off|stock)"; ok=false; return ;;
    esac
    # Only the entry whose label is exactly vmlinuz-74rc2 — the diagnostic
    # entries (…-nomodeset, …-debug) must keep their own extra parameters.
    python3 - "$ELILO" "$tokens" <<'PYEOF'
import sys
path, tokens = sys.argv[1:3]
lines = [l.rstrip('\n') for l in open(path)]

header, blocks, cur = [], [], None
for line in lines:
    if line.strip().startswith('image='):
        if cur is not None:
            blocks.append(cur)
        cur = [line]
    elif cur is None:
        header.append(line)
    else:
        cur.append(line)
if cur is not None:
    blocks.append(cur)

def label(b):
    for l in b:
        if l.strip().startswith('label='):
            return l.strip().split('=', 1)[1].strip()
    return ''

changed = False
for b in blocks:
    if label(b) != 'vmlinuz-74rc2':
        continue
    for i, line in enumerate(b):
        if line.strip().startswith('append='):
            value = line.strip().split('=', 1)[1].strip().strip('"')
            keep = [w for w in value.split() if not w.startswith((
                'xe.enable_psr=', 'xe.enable_psr2_sel_fetch=', 'xe.enable_panel_replay=',
                'xe.psr_safest_params=', 'xe.enable_fbc=', 'xe.enable_dsb=',
                'xe.enable_dpt=', 'xe.enable_ips='))]
            b[i] = '\tappend="%s"' % ' '.join(keep + ([tokens] if tokens else []))
            changed = True
if not changed:
    sys.exit("no append= line in the vmlinuz-74rc2 entry")
open(path, 'w').write('\n'.join(header + [l for b in blocks for l in b]).rstrip() + '\n')
print("  vmlinuz-74rc2 append: %s" % (tokens or "(kernel defaults)"))
PYEOF
}

do_diag() {
    # Two extra boot entries for the SAME 7.4 image. Both exist because on this
    # machine efifb fails ("efifb: abort, cannot remap video memory"), so the
    # text console is provided BY the GPU driver. Therefore:
    #   * nomodeset   -> no DRM -> no console at all (blank, not necessarily hung)
    #   * initcall_debug -> every initcall is printed as it starts, so the LAST
    #     line on screen names the function that hung. The EFI early console
    #     registers itself when booted via the stub, which is why boot text is
    #     visible at all on this machine.
    python3 - "$ELILO" "$NEW_APPEND" <<'PYEOF'
import sys
path, append = sys.argv[1:3]
lines = [l.rstrip('\n') for l in open(path)]

# split into: header (before first image=) and image blocks
header, blocks, cur = [], [], None
for line in lines:
    if line.strip().startswith('image='):
        if cur is not None:
            blocks.append(cur)
        cur = [line]
    elif cur is None:
        header.append(line)
    else:
        cur.append(line)
if cur is not None:
    blocks.append(cur)

diag_labels = {'vmlinuz-74rc2-nomodeset', 'vmlinuz-74rc2-debug'}

def block_label(block):
    for l in block:
        if l.strip().startswith('label='):
            return l.strip().split('=', 1)[1].strip()
    return ''

blocks = [b for b in blocks if block_label(b) not in diag_labels]

blocks.append(['image=vmlinuz-74rc2',
               '\tlabel=vmlinuz-74rc2-nomodeset',
               '\tdescription="7.4 diagnostic - no GPU driver (1: may be blank)"',
               '\tread-only',
               '\tappend="%s nomodeset"' % append])
blocks.append(['image=vmlinuz-74rc2',
               '\tlabel=vmlinuz-74rc2-debug',
               '\tdescription="7.4 diagnostic - last screen line = hung function"',
               '\tread-only',
               '\tappend="%s ignore_loglevel initcall_debug keep_bootcon"' % append])

out = header + [l for b in blocks for l in b]
open(path, 'w').write('\n'.join(out).rstrip() + '\n')
print("  diagnostic entries refreshed: nomodeset, debug")
PYEOF
}

do_default() {
    local which="${2:-new}" label
    case "$which" in
        new) label="$NEW_LABEL" ;;
        old) label="$OLD_LABEL" ;;
        *) note "ERROR: use 'default new|old'"; ok=false; return ;;
    esac
    cp -a "$ELILO" "$ELILO.bak-$(date +%Y%m%d-%H%M%S)"
    sed -i "s|^default=.*|default=$label|" "$ELILO"
    note "default entry is now: $(grep -m1 '^default=' "$ELILO")"
}

# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# cleanup / purge — undo the whole 7.4 experiment.
#
# The display freeze turned out to be the DSB engine (doc/display-freeze.md),
# fixed by `xe.enable_dsb=0` on the existing kernel, so the extra kernel is no
# longer needed. `cleanup` removes the boot entries, the image, its module tree
# and the boot menu furniture; `purge` additionally deletes the build trees.
# The 7.2.15 entry (with xe.enable_dsb=0 …) is left exactly as it is.
do_cleanup() {
    [ -f "$ELILO" ] || { note "ERROR: $ELILO not found"; ok=false; return; }
    cp -a "$ELILO" "$ELILO.bak-$(date +%Y%m%d-%H%M%S)"

    python3 - "$ELILO" <<'PYEOF'
import sys
path = sys.argv[1]
lines = [l.rstrip('\n') for l in open(path)]

header, blocks, cur = [], [], None
for line in lines:
    if line.strip().startswith('image='):
        if cur is not None:
            blocks.append(cur)
        cur = [line]
    elif cur is None:
        header.append(line)
    else:
        cur.append(line)
if cur is not None:
    blocks.append(cur)

def label(b):
    for l in b:
        if l.strip().startswith('label='):
            return l.strip().split('=', 1)[1].strip()
    return ''

kept = [b for b in blocks if label(b) == 'vmlinuz']
dropped = [label(b) for b in blocks if label(b) != 'vmlinuz']
if not kept:
    sys.exit("refusing: would leave no boot entry")

# single entry -> no chooser, no prompt, no message file, no countdown
DROP_PREFIXES = ('prompt', 'message=', 'timeout=', 'chooser=')
header = [l for l in header if not l.strip().startswith(DROP_PREFIXES)]
if not any(l.strip().startswith('default=') for l in header):
    header.append('default=vmlinuz')
else:
    header = [('default=vmlinuz' if l.strip().startswith('default=') else l) for l in header]
if not any(l.strip().startswith('delay=') for l in header):
    header.append('delay=5')

open(path, 'w').write('\n'.join(header + [l for b in kept for l in b]).rstrip() + '\n')
print("  elilo: kept 'vmlinuz', dropped: %s" % (', '.join(dropped) if dropped else 'nothing'))
PYEOF

    rm -f "$BOOT_DEST/vmlinuz-74rc2" "$BOOT_DEST/elilo.msg" && note "removed the 7.4 image and its menu message"
    if [ -d /lib/modules/7.4.0-rc2-wcl ]; then
        rm -rf /lib/modules/7.4.0-rc2-wcl && note "removed /lib/modules/7.4.0-rc2-wcl"
    else
        note "no /lib/modules/7.4.0-rc2-wcl"
    fi
    depmod -a "$(uname -r)" 2>/dev/null && note "depmod refreshed for $(uname -r)"

    echo "  --- $ELILO ---"
    sed 's/^/    /' "$ELILO"
    grep -q 'enable_dsb=0' "$ELILO" || { note "ERROR: the DSB fix is not in the remaining entry!"; ok=false; }
}

do_purge() {
    local freed
    freed=$(du -sh "$WORK" 2>/dev/null | cut -f1)
    if [ -d "$WORK" ]; then
        rm -rf "$WORK" && note "removed $WORK (${freed:-?} reclaimed)"
    else
        note "$WORK already gone"
    fi
    # the module-build helper is useless without the tree
    rm -rf /var/cache/powerkey-hold 2>/dev/null || true
}

do_status() {
    note "source   : $([ -d "$SRC_DIR" ] && echo "$SRC_DIR" || echo 'not fetched')"
    if [ -d "$SRC_DIR" ]; then
        note "release  : $(kernelrelease)"
        note "bzImage  : $([ -f "$SRC_DIR/arch/x86/boot/bzImage" ] && du -h "$SRC_DIR/arch/x86/boot/bzImage" | cut -f1 || echo 'not built')"
        note "fix      : $(grep -q skip_su_area_calc "$SRC_DIR/drivers/gpu/drm/i915/display/intel_psr.c" && echo 'cbe5654759 present' || echo 'absent')"
    fi
    note "modules  : $(ls -d /lib/modules/7.4* 2>/dev/null | tr '\n' ' ')"
    note "boot img : $(ls -l $BOOT_DEST/vmlinuz-74rc2 2>/dev/null | awk '{print $5" bytes"}' || echo 'not installed')"
    note "running  : $(uname -r)"
    if [ -f "$ELILO" ]; then
        note "elilo default: $(grep -m1 '^default=' "$ELILO" || echo '(first image entry)')"
        echo "  elilo entries:"
        grep -E '^[[:space:]]*(image|label)=' "$ELILO" | sed 's/^/    /'
    fi
}

case "$ACTION" in
    fetch)   do_fetch ;;
    build)   do_build ;;
    install) do_install ;;
    bootmenu) do_bootmenu ;;
    display)  do_display "$@" ;;
    diag)     do_diag ;;
    cleanup)  do_cleanup ;;
    purge)    do_purge ;;
    default)  do_default "$@" ;;
    status)  do_status ;;
    *) echo "ERROR: unknown action '$ACTION' (fetch|build|install|bootmenu|display|diag|default|cleanup|purge|status)"; exit 1 ;;
esac

$ok || { echo "FAILED: see messages above."; exit 1; }
exit 0
