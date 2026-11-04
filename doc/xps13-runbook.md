# XPS 13 — Slackware 16.0 (current) install runbook

Media: the stick built by `steps/usb-slackware.sh`.
Provenance: package series and installer procedure below follow this repo's
`readme.txt` ("SERIES — select these: A AP D L N X XAP"), not the full DVD set.

Pre-done on the stick: GRUB EFI loader, `generic.s` kernel, installer initrd,
packages for **a ap d l n x xap**, and WiFi credentials in `/provision/wifi/`.
**No network is needed to install.**

---

## 1. BIOS (the only unavoidable manual part)

1. Stick in, power on, **F2** at the Dell logo.
2. Set **Boot mode = UEFI** (not Legacy/CSM — the stick has no BIOS loader).
3. Set **Secure Boot = DISABLED**. Slackware ships unsigned kernels with no
   shim, so Secure Boot will refuse this stick. ("Try Secure Boot first" advice
   found online is wrong for Slackware.)
4. **F10** to save, then **F12** for the one-time boot menu.
5. Pick **`UEFI: <stick name>`**. The entry without the `UEFI:` prefix is legacy
   and will fail.

---

## 2. GRUB menu

| Entry | When |
|---|---|
| `Slackware 16.0 generic.s kernel` | **First choice.** |
| `... (use nomodeset)` | Install screen freezes/black — stock Slackware fix. |
| `... (XPS13 video=1024x768)` | Same freeze, alternative. |

The XPS 13 freeze is a display-mode issue, not a USB issue. Both workarounds are
already menu entries, so no kernel-line editing at the boot prompt.

---

## 3. `setup`

Log in as `root` (no password), run `setup`.

1. **Partition first**, in a shell: `cgdisk /dev/nvme0n1` — the XPS disk is
   `nvme0n1`, **never** `sda`. Three partitions:

   | Size | Type code | Purpose |
   |---|---|---|
   | 512 MB | `EF00` | EFI System Partition |
   | 2× RAM | `8200` | Linux swap |
   | remainder | `8300` | Linux filesystem (root) |

2. **ADDSWAP** — select swap, let setup format it.
3. **TARGET** — select root, format **ext4**.
4. **SOURCE** — *the installer's "Scan USB Drives" option will NOT find this
   stick.* Mount it by hand:
   - `Alt+F2`, press Enter for a shell
   - `mount /dev/sda1 /mnt`
     (NVMe is `nvme0n1`, so the stick enumerates as `sda`. Confirm with
     `fdisk -l` if unsure.)
   - `Alt+F1` back to the installer
   - SOURCE → **"Install from a pre-mounted directory"** → enter
     **`/mnt/slackware64`**
5. **SELECT** — tick exactly: **A, AP, D, L, N, X, XAP**
   - `N` matters: it provides `wpa_supplicant` / NetworkManager.
   - `A` includes `kernel-firmware`, which carries the `iwlwifi` firmware —
     without it the WiFi card is dead.
6. **PROMPT** — `full`.
7. **NETWORK** — skip (handled after install).
8. **FONT** — `ter-v32b` (or skip; `bootstrap.sh` sets it).
9. **LILO** — skip (UEFI machine). **Bootloader** — install the EFI loader to
   the ESP (`/dev/nvme0n1p1`). Slackware 15.0 offers ELILO; `-current` also
   ships GRUB — either is fine, both are on the stick.
10. Set the root password, **EXIT**, reboot, remove the stick.

---

## 4. First boot — WiFi without typing anything

The stick carries `provision/wifi/`, generated from `setup.keys.root`:

```sh
mount /dev/sda1 /mnt          # if not auto-mounted
sh /mnt/provision/wifi/apply-wifi.sh
```

That installs a NetworkManager profile for **`iPC’s iPhone`** with
`autoconnect=true`, so it joins at every boot thereafter. If NetworkManager is
missing, it falls back to `/etc/wpa_supplicant.conf` and prints the
`rc.inet1.conf` lines to add.

> The SSID's apostrophe is **U+2019 (’)**, not ASCII `'`. If you ever retype it
> by hand and it will not associate, that is the reason — copy the file instead.

---

## 5. Then the repo pipeline

```sh
REPO_DIR=/root/slackware-installer-for-rs bash bootstrap.sh
```

Reads `setup.keys.root` (now holding the correct `WIFI_SSID`/`WIFI_PASS`) and
runs the idempotent steps. `steps/wifi.sh` additionally appends
`pcie_aspm=off iwlwifi.power_save=0 i915.fastboot=1 i915.enable_psr=0` to the
bootloader, which is what keeps iwlwifi stable on these machines.

---

## Facts baked into the stick

- `-current` == **Slackware 16.0**; UEFI boot is **GRUB**, not ELILO
  (`EFI/BOOT/bootx64.efi`; there is no `elilo.conf`). ELILO-centric advice is stale.
- `/kernels/generic.s/bzImage` must be at that exact path: `grub-embedded.cfg`
  inside `bootx64.efi` runs `search --file --set=root /kernels/generic.s/bzImage`
  and adopts that partition as root.
- Installer kernel is `generic.s` — `-current` has no `huge.s` at all.
- Kernel, initrd and GRUB come from a single `usbboot.img` build → matched set.
