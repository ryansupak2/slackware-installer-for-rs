The purpose of this doc is to get Slackware set up after the successful ISO install to the machine. You'll have to type the stuff in this readme manually in practice, as you won't have the script down yet. This all assumes Slackware was installed with at least the following packages before you start:
```
A, AP, D, L, N, X, XAP
```

***

Pull the code down to root on the target machine:
```
cd ~

git -c http.sslVerify=false clone https://YOUR_PAT@github.com/ryansupak2/slackware-installer-for-rs.git
```
(Notice that this bypasses SSL just for this one instance; this is to temporarily sidestep a required Cert upgrade that post-installer.sh handles).

***

Gather required items and paste them in config.txt(pass? something else?)
```
some examples go here
```

***

Grant execute permissions for the installer script:
```
# grant execute permissions to installer script
chmod +x /root/slackware-installer-for-rs/post-install.sh
```

***



run the script (:
```
./root/slackware-installer-for-rs/post-install.sh
```
