The purpose of this doc is to get Slackware set up after the successful ISO install to the machine. You'll have to type the stuff in this readme manually in practice, as you won't have the script down yet. This all assumes Slackware was installed with at least the following packages before you start:
```
A, AP, D, L, N, X, XAP
```

***

First, you'll need to manually create an SSH key locally (this will need to be done per-user in order to pull down the Repo):

```
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "MyPassphrase" -C "MyUser@MyEmail.com"

eval "$(ssh-agent -s)"

ssh-add ~/.ssh/id_ed25519
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
