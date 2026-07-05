SLACKWARE LINUX POST-INSTALL
=============================
Fresh Slackware 15.0 install -> working Wayland desktop (ThinkPad X13).


PREREQUISITES
-------------

1. Install Slackware 15.0 from ISO. Partition the drive as follows:

   - 512 MB        EFI System Partition (type EF00 in gdisk/cgdisk)
   - 2x RAM size   Linux Swap (e.g. 32 GB for 16 GB RAM)
   - Remainder     Linux Filesystem (type 8300)

2. During package selection, install these series:

       A     Base Linux system
       AP    Applications (non-X)
       D     Development tools (gcc, make, headers)
       L     Libraries
       N     Networking
       X     X Window System + XWayland
       XAP   X Applications (Firefox, Inkscape, etc.)

3. After install, boot into Slackware. Plug in a USB stick containing
   this repo (slackware-installer-for-rs/). Edit setup.keys.root on the
   USB with at minimum:

       WIFI_SSID=YourNetwork
       WIFI_PASS=YourPassword
       DEEPSEEK_API_KEY=sk-...

4. Mount the USB, enter the repo, and make scripts executable:

       mount /dev/sdb1 /mnt/usb
       cd /mnt/usb/slackware-installer-for-rs
       chmod +x bootstrap.sh post-install-global.sh post-install-user.sh


STEPS
-----

1. BOOTSTRAP
   Run bootstrap.sh. It auto-connects to WiFi, installs nodejs22 from
   SBo, downloads the pi coding agent, and deploys root dotfiles:

       ./bootstrap.sh

2. FILL IN REMAINING KEYS
   Edit setup.keys.root: add NordVPN, GitHub PAT, SSH keys, etc.
   See setup.keys.example. (NordVPN 2FA: token from nordaccount.com)

3. GLOBAL INSTALLER
   Interactive menu (A = all). Categories: Core, Networking, Hardware,
   Security, Dev Tools, UI, Apps, Utilities.

       ./post-install-global.sh

4. PER-USER SETUP
   For each desktop user:

       ./post-install-user.sh --user alice --wheel

   Creates user, desktop groups, sudo (--wheel), dotfiles (Y/N safety).

5. START DESKTOP
   Log in as user, run:

       dwl-start


PACKAGE MANAGEMENT
------------------
Two package helpers with no fallbacks:
  install_pkg   - slackpkg for official Slackware packages
  install_sbo   - sbopkg for SlackBuilds.org packages

Already-installed packages are detected and skipped (idempotent).


INIT SYSTEM
-----------
Slackware uses BSD-style init scripts in /etc/rc.d/. Services are
controlled by making scripts executable and calling them directly:
  /etc/rc.d/rc.networkmanager start
  /etc/rc.d/rc.acpid restart
  chmod +x /etc/rc.d/rc.font          # enable at boot

rc.M runs executable scripts in /etc/rc.d/ at boot. rc.local is for
custom startup commands.


WAYLAND + DWL
-------------
Uses dwl (Wayland compositor, dwm port) + somebar + foot terminal.
wayland and wayland-protocols are built from source. seatd-launch
manages seat access per-session.


NEOFETCH
--------
Uses bobdobbs.txt ASCII art as the default splash. Deployed to both
root and each user's ~/.config/neofetch/.
