Slackware Post-Install. To use:

# NOTE: this all assumes Slackware was installed with the following packages before you start:
```
A, AP, D, L, N, X, XAP
```

# edit the mirrors file, uncommenting EXACTLY ONE mirror.
(this enables slackpkg to work so we can pull necessary stuff down from Slackware)
```
vi etc/slackpkg/mirrors
```

# this is to ensure that git can bring stuff down from github.com
```
slackpkg update
slackpkg install ca-certificates
update-ca-certificates
```

# pull the code down to root on the target machine
```
cd ~
git -c http.sslVerify=false clone https://YOUR_PAT@github.com/ryansupak2/slackware-installer-for-rs.git

# grant execute permissions to installer script
chmod +x /root/slackware-installer-for-rs/post-install.sh

# run it (:
./root/slackware-installer-for-rs/post-install.sh
```
