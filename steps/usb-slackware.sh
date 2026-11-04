#!/usr/bin/env bash
#
# usb-slackware.sh — build a UEFI-bootable Slackware 16.0 (current) USB installer
#
# Target is a FREEBSD host, so this uses gpart/newfs_msdos/mdconfig rather than
# Linux tooling (sgdisk/mkfs.vfat do not exist here).
#
# Layout written to the stick (single FAT32 GPT partition, ISO-equivalent paths):
#   /EFI/BOOT/bootx64.efi     GRUB EFI loader (slackware64-current still ships
#                             grub, NOT elilo, for UEFI boot)
#   /EFI/BOOT/grub.cfg        menu; patched with an XPS13 video=1024x768 entry
#   /kernels/generic.s/bzImage
#   /isolinux/initrd.img
#   /slackware64/{a,ap,...}/  full package tree -> offline install, no network
#
# The path /kernels/generic.s/bzImage is mandatory: grub-embedded.cfg inside
# bootx64.efi does `search --file --set=root /kernels/generic.s/bzImage`,
# so the partition holding that exact path is the one GRUB adopts as root.
#
# Usage:
#   USB_DEV=da0 bash steps/usb-slackware.sh stage      # download only (safe)
#   USB_DEV=da0 CONFIRM_WIPE=yes bash steps/usb-slackware.sh format   # DESTRUCTIVE
#   USB_DEV=da0 bash steps/usb-slackware.sh populate   # copy files to stick
#   USB_DEV=da0 bash steps/usb-slackware.sh all        # stage+format+populate
#
# Idempotent: downloads resume and are md5-verified against the upstream
# CHECKSUMS.md5; the stick build is skipped when a completion marker exists.

set -uo pipefail

REPO_DIR=${REPO_DIR:-/root/slackware-installer-for-rs}
# NOTE: the canonical default above matches every other step in this repo
# (and tests/installer-simulation.sh Test 2). Always invoke with REPO_DIR
# set explicitly, per AGENTS.md.
# leaseweb measured ~4.0MB/s; mirrors.slackware.com redirected to ~150KB/s
MIRROR=${MIRROR:-https://mirror.us.leaseweb.net/slackware/slackware64-current}
STAGE=${STAGE:-/var/tmp/slack16-stage}
USB_DEV=${USB_DEV:-da0}
USB_PART="${USB_DEV}p1"
MOUNT=${MOUNT:-/mnt/slackusb}
MARKER=/slackware64/PACKAGES.TXT          # presence on stick == populated
LOG_FILE=${LOG_FILE:-/var/log/${USER:-root}-usb-slackware-$(date +%Y%m%d-%H%M%S).log}

# Package series to stage: exactly what this repo's readme.txt requires
# ("SERIES - select these: A AP D L N X XAP").  Deliberately does NOT include
# e/f/k/kde/t/tcl/xfce/y: nothing in steps/ needs them, and they would add
# ~2GB of dead weight to the stick.
SECTIONS=${SECTIONS:-a ap d l n x xap}

mkdir -p "$STAGE"

# House convention: source the shared helpers when present (Test 3), and track
# overall success in $ok (Test 5). This step runs on the FreeBSD build host,
# so it installs no packages itself -- it only writes an image to a USB key.
if [ -f "$REPO_DIR/lib/common.sh" ]; then
  . "$REPO_DIR/lib/common.sh"
fi
ok=true
exec > >(tee -a "$LOG_FILE") 2>&1

log()  { echo "[$(date +%H:%M:%S)] $*"; }
die()  { echo "[$(date +%H:%M:%S)] FATAL: $*" >&2; ok=false; exit 1; }

echo "*****************************************************"
echo "USB SLACKWARE INSTALLER BUILDER"
echo "*****************************************************"

# ---------------------------------------------------------------- safety gate
check_device() {
  [ -c "/dev/$USB_DEV" ] || die "/dev/$USB_DEV does not exist"
  case "$USB_DEV" in
    nda*|nvd*|ada*) die "refusing internal/system disk: $USB_DEV" ;;
  esac
  # Must be a USB-attached device. On FreeBSD: camcontrol devlist shows it at
  # scbusN; the cheap and reliable check is the geom description string.
  local descr
  descr=$(geom disk list "$USB_DEV" 2>/dev/null | awk '/descr:/{sub(/descr: /,"");print;exit}')
  [ -n "$descr" ] || die "cannot read geom description for $USB_DEV"
  case "$descr" in
    *USB*|*Flash*|*Stick*|*Memory*) : ;;
    *) die "$USB_DEV ($descr) does not look like a USB stick" ;;
  esac
  local size
  size=$(geom disk list "$USB_DEV" | awk '/Mediasize:/{printf "%.1f GiB", $2/1073741824;exit}')
  log "target verified: /dev/$USB_DEV = '$descr' ($size)"
  if mount -p | grep -q "/dev/${USB_PART}"; then
    die "/dev/$USB_PART is currently MOUNTED (see 'mount') - refusing to write"
  fi
}

# ---------------------------------------------------------------- phase: stage
fetch() { # fetch <relative-url-path> <dest>
  local rel=$1 dest=$2
  [ -s "$dest" ] && return 0
  mkdir -p "$(dirname "$dest")"
  curl -sSL --fail -C - -m 900 -o "$dest" "$MIRROR/$rel" || { rm -f "$dest"; return 1; }
}

phase_stage() {
  log "== phase: stage (mirror $MIRROR)"
  fetch slackware64/CHECKSUMS.md5 "$STAGE/CHECKSUMS.md5" || die "cannot fetch CHECKSUMS.md5"
  fetch slackware64/PACKAGES.TXT  "$STAGE/PACKAGES.TXT"  || true

  # --- boot files: taken from the official usbboot.img mini-ISO so that
  # kernel/initrd/grub are a self-consistent set from the same build.
  if [ ! -s "$STAGE/usbboot.img" ]; then
    log "fetching usbboot.img (123MB mini-ISO)"
    fetch usb-and-pxe-installers/usbboot.img "$STAGE/usbboot.img" || die "usbboot.img failed"
  fi
  if [ ! -s "$STAGE/EFI/BOOT/bootx64.efi" ] || [ ! -s "$STAGE/isolinux/initrd.img" ]; then
    local md
    md=$(mdconfig -a -t vnode -f "$STAGE/usbboot.img") || die "mdconfig failed"
    mkdir -p /mnt/ub
    mount -t cd9660 -o ro "/dev/$md" /mnt/ub || die "mount mini-ISO failed"
    log "extracting EFI/, kernels/, isolinux/initrd.img from mini-ISO"
    mkdir -p "$STAGE/EFI" "$STAGE/kernels" "$STAGE/isolinux"
    cp -R /mnt/ub/EFI/BOOT "$STAGE/EFI/"            || die "copy EFI/BOOT failed"
    cp -R /mnt/ub/kernels/generic.s "$STAGE/kernels/" >/dev/null || die "copy kernel failed"
    cp    /mnt/ub/isolinux/initrd.img "$STAGE/isolinux/"  || die "copy initrd failed"
    umount /mnt/ub
    mdconfig -d -u "${md#md}"
  fi
  log "boot set: bzImage $(stat -f %z "$STAGE/kernels/generic.s/bzImage") bytes, initrd $(stat -f %z "$STAGE/isolinux/initrd.img") bytes"

  # --- package tree, driven by the upstream md5 manifest (paths are ./a/foo.txz)
  : > "$STAGE/urls.txt"
  local sec
  for sec in $SECTIONS; do
    awk -v s="./$sec/" 'index($2,s)==1 && /\.t[xg]z$/ {print $2}' "$STAGE/CHECKSUMS.md5" \
      | sed 's|^\./|slackware64/|' >> "$STAGE/urls.txt"
  done
  local n
  n=$(wc -l < "$STAGE/urls.txt" | tr -d ' ')
  log "manifest: $n packages across: $SECTIONS"
  [ "$n" -gt 500 ] || die "manifest looks wrong ($n packages)"

  log "downloading packages (8 parallel, resumable)..."
  local failed="$STAGE/failed.txt"
  : > "$failed"
  export MIRROR STAGE
  xargs -P 8 -n 1 bash -c '
    rel="$1"; dest="$STAGE/$rel"
    [ -s "$dest" ] && exit 0
    mkdir -p "$(dirname "$dest")" 2>/dev/null
    curl -sSL --fail -C - -m 1800 -o "$dest" "$MIRROR/$rel" 2>/dev/null \
      || { rm -f "$dest"; echo "$rel" >> "'"$failed"'"; }
  ' _ < "$STAGE/urls.txt"
  local nf
  nf=$(wc -l < "$failed" | tr -d ' ')
  [ "$nf" -eq 0 ] || { log "WARNING: $nf downloads failed (rerun 'stage' to retry)"; head -5 "$failed"; }

  log "verifying md5 against upstream manifest..."
  local bad=0 checked=0
  while read -r sum path; do
    [ -f "$STAGE/$path" ] || continue
    checked=$((checked + 1))
    [ "$(md5 -q "$STAGE/$path")" = "$sum" ] || { log "  BAD md5: $path"; bad=$((bad + 1)); }
  done < <(awk '{p=$2; sub(/^\.\//,"slackware64/",p); print $1, p}' "$STAGE/CHECKSUMS.md5")
  log "verified $checked files, $bad bad"
  [ "$bad" -eq 0 ] || die "$bad files failed md5 verification"
  date > "$STAGE/.staged"
  log "== phase: stage complete ($(du -sh "$STAGE" | awk '{print $1}') staged)"
}

# --------------------------------------------------------------- phase: format
phase_format() {
  log "== phase: format"
  check_device
  [ "${CONFIRM_WIPE:-no}" = "yes" ] || die "set CONFIRM_WIPE=yes to allow erasing /dev/$USB_DEV"
  log "ERASING /dev/$USB_DEV (GPT + single FAT32 ESP)"
  # -F forces removal even though the existing table is flagged [CORRUPT]
  gpart destroy -F "$USB_DEV" >/dev/null 2>&1 || true
  gpart create -s gpt "$USB_DEV"                       || die "gpart create failed"
  # Single partition spanning the disk; type efi => GPT type EF00.
  gpart add -t efi -l SLACKUSB "$USB_DEV"              || die "gpart add failed"
  # 32K clusters keep the FAT small and writes fast for ~5.3GB of packages.
  newfs_msdos -F 32 -c 64 -L SLACKUSB "/dev/$USB_PART" || die "newfs_msdos failed"
  gpart show "$USB_DEV"
  log "== phase: format complete"
}

# ------------------------------------------------------------- phase: populate
phase_populate() {
  log "== phase: populate"
  [ -f "$STAGE/.staged" ] || die "stage not complete - run 'stage' first"
  mkdir -p "$MOUNT"
  mount -t msdosfs "/dev/$USB_PART" "$MOUNT" || die "cannot mount /dev/$USB_PART"
  if [ -f "$MOUNT$MARKER" ]; then
    log "stick already populated ($MARKER present) - skipping copy"
  else
    log "copying boot set..."
    mkdir -p "$MOUNT/EFI" "$MOUNT/kernels" "$MOUNT/isolinux" "$MOUNT/slackware64"
    cp -R "$STAGE/EFI/BOOT"        "$MOUNT/EFI/"                     || die "copy EFI failed"
    cp -R "$STAGE/kernels/generic.s" "$MOUNT/kernels/"               || die "copy kernel failed"
    cp    "$STAGE/isolinux/initrd.img" "$MOUNT/isolinux/"            || die "copy initrd failed"
    cp    "$STAGE/PACKAGES.TXT"    "$MOUNT/slackware64/" 2>/dev/null || true
    cp    "$STAGE/CHECKSUMS.md5"   "$MOUNT/slackware64/" 2>/dev/null || true

    log "installing patched grub.cfg (adds XPS13 video=1024x768 entry)..."
    write_grub_cfg > "$MOUNT/EFI/BOOT/grub.cfg"                      || die "grub.cfg failed"
    if [ -d "$STAGE/provision" ]; then
      log "copying provision/ (wifi credentials, runbook)..."
      mkdir -p "$MOUNT/provision"
      cp -R "$STAGE/provision/." "$MOUNT/provision/" || die "copy provision failed"
    fi

    log "copying package tree (this is the slow part)..."
    local total done_n=0
    total=$(du -sk "$STAGE"/slackware64 | awk '{print $1}')
    local sec
    for sec in $SECTIONS; do
      [ -d "$STAGE/slackware64/$sec" ] || continue
      mkdir -p "$MOUNT/slackware64/$sec"
      cp -R "$STAGE/slackware64/$sec/." "$MOUNT/slackware64/$sec/"  || die "copy $sec failed"
      done_n=$((done_n + 1))
      log "  $sec done ($(( $(du -sk "$MOUNT/slackware64" | awk '{print $1}') / 1024 ))MB of $((total/1024))MB)"
    done
    sync
  fi
  log "free space on stick: $(df -h "$MOUNT" | awk 'NR==2{print $4}')"
  umount "$MOUNT" || die "umount failed"
  log "== phase: populate complete"
}

# Custom grub.cfg: official menu entries, plus an explicit XPS 13 entry using
# video=1024x768 (the classic fix for the XPS 13 install-screen freeze).
write_grub_cfg() {
  cat <<'GRUB'
# Slackware USB installer grub.cfg (generated by steps/usb-slackware.sh)

set default="0"
set timeout="30"
set hidden_timeout_quiet=false

DISPLAY_TYPE=console

function load_video {
  if [ x$grub_platform = xefi ]; then
    insmod efi_gop
  elif [ x$feature_all_video_module = xy ]; then
    insmod all_video
  else
    insmod efi_gop
    insmod vbe
    insmod vga
  fi
}

if [ "$DISPLAY_TYPE" = "console" ]; then
  terminal_input console
  terminal_output console
fi

if [ x$feature_timeout_style = xy ] ; then
  set timeout_style=menu
  set timeout=90
else
  set timeout=90
fi

menuentry "Slackware 16.0 generic.s kernel"{
  echo "Loading generic.s kernel and installer initrd.  Please wait..."
  linux /kernels/generic.s/bzImage vga=normal ro printk.time=0 SLACK_KERNEL=generic.s
  initrd /isolinux/initrd.img
}

menuentry "Slackware 16.0 generic.s kernel (use nomodeset)"{
  echo "Loading generic.s kernel (nomodeset) and installer initrd.  Please wait..."
  linux /kernels/generic.s/bzImage vga=normal ro printk.time=0 nomodeset SLACK_KERNEL=generic.s
  initrd /isolinux/initrd.img
}

menuentry "Slackware 16.0 generic.s kernel (XPS13 video=1024x768)"{
  echo "Loading generic.s kernel (video=1024x768) and installer initrd.  Please wait..."
  linux /kernels/generic.s/bzImage vga=normal ro printk.time=0 video=1024x768 SLACK_KERNEL=generic.s
  initrd /isolinux/initrd.img
}

menuentry "Detect/boot any installed operating system" {
  configfile "/EFI/BOOT/osdetect.cfg"
}
GRUB
}

# --------------------------------------------------------------- phase: verify
# ------------------------------------------------------------- phase: provision
# Stages WiFi credentials from the repo keys file onto the stick so the target
# can reach the network without anyone typing an SSID. The SSID contains
# U+2019, so it is copied as bytes -- never retyped.
phase_provision() {
  log "== phase: provision"
  local keys="$REPO_DIR/setup.keys.root"
  [ -f "$keys" ] || die "missing $keys"
  # shellcheck disable=SC1090
  . "$keys"
  [ -n "${WIFI_SSID:-}" ] || die "WIFI_SSID unset in $keys"
  [ -n "${WIFI_PASS:-}" ] || die "WIFI_PASS unset in $keys"

  local pw="$STAGE/provision/wifi"
  mkdir -p "$pw"

  # 1) wpa_supplicant.conf — portable, used by the installer shell too
  cat > "$pw/wpa_supplicant.conf" <<EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=wheel
update_config=1

network={
        ssid="$WIFI_SSID"
        psk="$WIFI_PASS"
}
EOF

  # 2) NetworkManager keyfile — this repo's steps/wifi.sh uses NetworkManager
  cat > "$pw/nm-keyfile" <<EOF
[connection]
id=$WIFI_SSID
uuid=$(uuidgen 2>/dev/null || echo 00000000-0000-4000-8000-000000000000)
type=wifi
autoconnect=true
autoconnect-priority=10

[wifi]
mode=infrastructure
ssid=$WIFI_SSID

[wifi-security]
key-mgmt=wpa-psk
psk=$WIFI_PASS

[ipv4]
method=auto
dns-search=

[ipv6]
method=auto
addr-gen-mode=stable-privacy
EOF

  # 3) apply script for the freshly installed system
  cat > "$pw/apply-wifi.sh" <<'APPLY'
#!/bin/sh
# Run on the freshly installed Slackware system: sh /mnt/provision/wifi/apply-wifi.sh
# Finds the USB mount holding provision/ and installs the WiFi config.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
if [ -x /etc/rc.d/rc.networkmanager ] || [ -d /etc/NetworkManager ]; then
  install -d -m 700 /etc/NetworkManager/system-connections
  # uuid is generated here so every machine gets its own
  sed "s|^uuid=.*|uuid=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)|" \
    "$HERE/nm-keyfile" > "/etc/NetworkManager/system-connections/wifi.nmconnection"
  chmod 600 /etc/NetworkManager/system-connections/wifi.nmconnection
  chmod +x /etc/rc.d/rc.networkmanager 2>/dev/null || true
  /etc/rc.d/rc.networkmanager restart 2>/dev/null || /etc/rc.d/rc.networkmanager start 2>/dev/null || true
  echo "NetworkManager connection installed; it will autoconnect."
else
  install -m 600 "$HERE/wpa_supplicant.conf" /etc/wpa_supplicant.conf
  echo "wpa_supplicant.conf installed (NetworkManager not found)."
  echo "Add to /etc/rc.d/rc.inet1.conf:  IFNAME[0]=wlan0  USE_DHCP[0]=yes  WLAN_WPA[0]=yes"
fi
APPLY
  chmod +x "$pw/apply-wifi.sh"

  cat > "$STAGE/provision/README.txt" <<EOF
Slackware 16.0 USB installer — provisioned payload
==================================================

wifi/            WiFi credentials for: $WIFI_SSID
                (SSID holds U+2019; do not retype it as an ASCII apostrophe)
wifi/apply-wifi.sh   run after first boot:  sh ./apply-wifi.sh
wifi/nm-keyfile      NetworkManager connection (auto-connect)
wifi/wpa_supplicant.conf  fallback if NM is not used

The install itself needs NO network: the full package tree is on this stick
under /slackware64. Choose the local/USB source during setup.
EOF

  log "provisioned WiFi for SSID '$WIFI_SSID' (pass len ${#WIFI_PASS})"
  log "NOTE: the stick now carries the WiFi PSK in cleartext (FAT has no perms)"
}


phase_verify() {
  log "== phase: verify"
  mkdir -p "$MOUNT"
  mount -t msdosfs -o ro "/dev/$USB_PART" "$MOUNT" || die "cannot mount"
  local ok=0
  for f in EFI/BOOT/bootx64.efi EFI/BOOT/grub.cfg kernels/generic.s/bzImage \
           isolinux/initrd.img slackware64/PACKAGES.TXT; do
    if [ -s "$MOUNT/$f" ]; then
      log "  OK   $f ($(stat -f %z "$MOUNT/$f") bytes)"
      ok=$((ok + 1))
    else
      log "  MISS $f"
    fi
  done
  local pk
  pk=$(find "$MOUNT/slackware64" -name '*.t?z' -o -name '*.t?z' 2>/dev/null | wc -l | tr -d ' ')
  log "  packages on stick: $pk"
  log "  grub entries: $(grep -c '^menuentry' "$MOUNT/EFI/BOOT/grub.cfg")"
  umount "$MOUNT"
  [ "$ok" -eq 5 ] || die "verification failed"
  log "== phase: verify complete"
}

case "${1:-all}" in
  stage)    phase_stage ;;
  format)   phase_format ;;
  populate) phase_populate ;;
  provision) phase_provision ;;
  verify)   phase_verify ;;
  all)      phase_stage && phase_provision && phase_format && phase_populate && phase_verify ;;
  *) die "usage: $0 {stage|provision|format|populate|verify|all}" ;;
esac
