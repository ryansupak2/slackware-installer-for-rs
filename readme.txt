SLACKWARE LINUX POST-INSTALL
=============================
Fresh Slackware 15.0 install -> working X11/DWM desktop (ThinkPad X13).


INSTALLING SLACKWARE
-------------------
GOTCHAS — Slackware's installer is minimal. Know these before starting.

1. Boot from the USB stick. At the boot prompt, just press Enter.

2. Partition the disk. Run cgdisk on your NVMe drive:

       cgdisk /dev/nvme0n1

   Create three partitions in this order:

       Size          Type    Code   Description
       512 MB                 EF00   EFI System Partition
       2x RAM size            8200   Linux Swap
       Remainder              8300   Linux Filesystem

   Write the table and quit.

3. Run the installer:

       setup

   Work through each menu item. Key choices at each screen:

   ADDSWAP  — select your swap partition, let it format
   TARGET   — select your root partition, format as ext4
   SOURCE   — Despite booting from the USB, the installer's "Scan USB
              Drives" option will NOT find it. You must manually mount it:

              1. Switch to console 2 (Alt+F2), press Enter to get a shell.
              2. Mount the USB:  mount /dev/sdb1 /mnt
              3. Switch back to the installer (Alt+F1).
              4. Choose SOURCE → "Install from a pre-mounted directory".
              5. Enter: /mnt/slackware64  (the USB mount + subdirectory).
   SERIES   — select these:

       A     Base Linux system
       AP    Applications (non-X)
       D     Development tools (gcc, make, headers)
       L     Libraries
       N     Networking
       X     X Window System
       XAP   X Applications (Firefox, Inkscape, etc.)

   PROMPT   — choose "full" (install everything without prompting)
   NETWORK  — skip (NetworkManager handles it later)
   FONT     — pick ter-v32b (or skip, bootstrap.sh sets it)
   LILO     — skip (UEFI system, use elilo below)
   ELILO    — install to the EFI partition

4. Set root password, exit setup, and reboot. Remove the USB.


AFTER INSTALL
-------------

1. After install, boot into Slackware. Log in as root with the
   password you set during setup.

2. Plug in the second USB stick containing this repo. Mount it:

       mkdir -p /mnt/usb
       mount /dev/sdb1 /mnt/usb   (check dmesg | tail for the device name)
       cd /mnt/usb/slackware-installer-for-rs

   setup.keys.root is pre-populated with WiFi and Deepseek keys.
   If you need to change them, edit setup.keys.root now:

       vi setup.keys.root   (or nano, or your preferred editor)

3. Make scripts executable and run bootstrap:

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

       dwm-start


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


DWM + XLIBRE
-------------
Uses dwm (X11 window manager, suckless) + st terminal.
xlibre provides screen color temperature adjustment (redshift
alternative) for X11. Deployed as a step under the UI category.


NEOFETCH
--------
Uses bobdobbs.txt ASCII art as the default splash. Deployed to both
root and each user's ~/.config/neofetch/.
