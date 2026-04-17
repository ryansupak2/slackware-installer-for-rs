Slackware Post-Install. To use:

```
# first, pull the code down to root on the target machine
cd ~
git -c http.sslVerify=false clone https://YOUR_PAT@github.com/ryansupak2/slackware-installer-for-rs.git

# grant execute permissions to installer script
chmod +x /root/slackware-installer-for-rs/post-install.sh

# run it (:
./root/slackware-installer-for-rs/post-install.sh
```
