#!/bin/bash

echo "Setting reasonable Font Size..."
setfont ter-v32b

echo "Copying Wifi Power Management Settings (to prevent random WiFi dropouts)..."
#TODO IMPLEMENT

echo "Setting Permissions for and then Starting Network Manager..."
chmod +x /etc/rc.d/rc.networkmanager
/etc/rc.d/rc.networkmanager start

echo "Fixing package manager GPG issue by removing then reinstalling latest of gnupg2..."
slackpkg -batch=on -default_answer=y remove gnupg2
slackpkg -batch=on -default_answer=y install gnupg2

echo "Setting mirror (to most reliable)..."
sed -i 's|^#http://mirrors.slackware.com/slackware/slackware64-15.0/|http://mirrors.slackware.com/slackware/slackware64-15.0/|' /etc/slackpkg/mirrors

echo "Fixing HTTPS/SSL..."
update-ca-certificates --fresh
ln -sf /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-bundle.crt
