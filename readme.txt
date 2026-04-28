The purpose of this document is to explain how to install Slackware on a "fresh" ThinkPad X13.

************************************************
* SLACKWARE BASE INSTALLATION                  *
************************************************

This documentation won't go into full detail on how to install Slackware except to say a few things:

* Install the ISO on a USB drive.

* The Hard Drive on the destination must have the following partitions before you start the install:

    - 512 MB - EFI Boot
 
    - 32 GB - Linux Swap

    - Remainder - Linux Filesystem

* It may be necessary to mount /usbinstall/slackware64 as a drive, and then to specify that as a pre-mounted drive endpoint as sometimes it can't find the USB drive directly.

* Install the following lettered packages of Slackware:

    - A, AP, D, L, N, X, XAP  
 
************************************************
* SLACKWARE POST-INSTALLATION                  *
************************************************

Overall, here are the steps that will transpire:

    - Perform the manual "boot-strapping" steps below. You will have to transcribe them as there is no connection to GitHub on this machine yet to download the files. You will also need a PAT token to get to this repo. The minimum required scopes are 'repo', 'read:org', 'admin:public_key'.
    
    - Run ~/post-install-global.sh as root (automatically copies repo to /usr/local/share, excluding sensitive setup.keys).
    
    - For each user: Root copies setup.keys to ~user/.local/share/opencode/. Then, as the user, run /usr/local/share/slackware-installer-for-rs/post-install-user.sh (prompts for overwrites to prevent data loss).

* SAFETY NOTES: User script prompts Y/N before overwriting files. setup.keys is excluded from shared repo for security—root must pre-copy it to user dirs.

***********************************************
* BOOTSTRAPPING                               *
***********************************************

The purpose of this step is to pull down the repo for this installer from Github.

    - Login as root.

    - Run nmtui and select a WiFi Network and login to it.

    - Generate an SSH Key on the target machine for root user:

ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "MyPassphrase" -C "MyUser@MyEmail.com"

eval "$(ssh-agent -s)"

ssh-add ~/.ssh/id_ed25519

    - Install sbopkg and github-cli in that order. (sbopkg is a Slackware package manager, and github-cli allows us to push our SSL key up to github with no web browser):

wget https://github.com/sbopkg/sbopkg/releases/download/0.38.3/sbopkg-0.38.3-noarch-1_wsr.tgz
 
installpkg sbopkg-0.38.3-noarch-1_wsr.tgz

sbopkg -B -i github-cli

    - Run the GitHub login:

gh auth login

    - Specify Github.com > SSH > point to the public key you generated > paste the GitHub PAT.

    - Pull the code down to root on the target machine:

 cd ~

 git clone git@github.com:ryansupak2/slackware-installer-for-rs.git

    - Gather required items and paste them in setup.keys:

WIFI_SSID=MyWifiNetworkName
WIFI_PASS=MyWifiPassword
XAI_API_KEY=MyXaiAPIKey
NORD_TOKEN=YourNordVPNAccessTokenFromWebsite

    (Notice that the format is strict: KEY=VALUE with no spaces or bounding quotes, etc...)*

    - For NordVPN with 2FA: Generate an access token from https://nordaccount.com/ (Services > NordVPN > Access Token) and use it for NORD_TOKEN.

    - Grant execute permissions for the installer script:

chmod +x /root/slackware-installer-for-rs/post-install-global.sh
chmod +x /root/slackware-installer-for-rs/post-install-user.sh

    - run the scripts:

 /root/slackware-installer-for-rs/post-install-global.sh (run as root; handles /usr/local/share copy).

 For users: As root, cp /root/slackware-installer-for-rs/setup.keys ~user/.local/share/opencode/.

 Then, as user: /usr/local/share/slackware-installer-for-rs/post-install-user.sh (interactive prompts for safe overwrites).
