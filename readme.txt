The purpose of this document is to explain how to install Slackware on a "fresh" ThinkPad X13.

************************************************
* SLACKWARE BASE INSTALLATION                  *
************************************************

This documentation won't go into much detail on how to install Slackware except to say a few things:

* Install the ISO on a USB drive.

* The Hard Drive on the destination must have the following partitions before you start the install:
    - 512 MB - EFI
    - 32 GB - Linux Swap
    - Remainder - Linux Filesystem

* It may be necessary to mount /usbinstall/slackware64 as a drive, and then to specify that as a pre-mounted drive endpoint as sometimes it can't find the USB drive directly.

* Install the following lettered packages of Slackware:

    - A, AP, D, L, N, X, XAP  
 
************************************************
* SLACKWARE POST-INSTALLATION                  *
************************************************

* Overall, here are the steps:
    - Perform the manual "boot-strapping" steps here. You will have to transcribe them as there is no connection to GitHub yet to download the files.
    - Run ~/post-install-global.sh as root.
    - root user copies the contents of this folder to /usr/local/share so that other users can access it, and copy it to their own /root/ and use it.
    - Run ~/post-install-user.sh for each user who will actually use the system.

***********************************************
* BOOTSTRAPPING                               *
***********************************************



```
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "MyPassphrase" -C "MyUser@MyEmail.com"

eval "$(ssh-agent -s)"

ssh-add ~/.ssh/id_ed25519
```

***

Next, you'll need to install sbopkg and github-cli in that order. (sbopkg is a Slackware package manager, and github-cli allows us to push our SSL key up to github with no web browser):

```

wget https://github.com/sbopkg/sbopkg/releases/download/0.38.3/sbopkg-0.38.3-noarch-1_wsr.tgz 
installpkg sbopkg-0.38.3-noarch-1_wsr.tgz

sbopkg -B -i github-cli

```

***

You'll need a PAT token from GitHub for the next part, in order to establish the SSH connection. So please go to github.com on some other machine (or phone, of course) and have that handy and ready to transcribe. The minimum required scopes are 'repo', 'read:org', 'admin:public_key'.

```

```

***

Pull the code down to root on the target machine:
```
cd ~
git -c http.sslVerify=false clone https://@github.com/ryansupak2/slackware-installer-for-rs.git
```
*(Notice that this bypasses SSL just for this one instance; this is to temporarily sidestep a required Cert upgrade that running post-install.sh handles later).*

***

Gather required items and paste them in config.txt(pass? something else?)
```
WIFI_SSID=MyWifiNetworkName
WIFI_PASS=MyWifiPassword
GITHUB_PAT=MyGithubPATWithRepoPermissions
```
*(Notice that the format is strict: KEY=VALUE with no spaces or bounding quotes, etc...)*

***

Grant execute permissions for the installer script:
```
chmod +x /root/slackware-installer-for-rs/post-install.sh
```

***



run the script (:
```
./root/slackware-installer-for-rs/post-install.sh
```
