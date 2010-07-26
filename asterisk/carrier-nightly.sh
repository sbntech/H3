#!/bin/bash

# nightly asterisk carrier refresh
# w6 is the carrier

killall asterisk
sleep 1
killall -KILL asterisk
rm -rf /var/log/asterisk/*

sudo -u grant /bin/bash -c '(cd /home/grant/sbn-git ; git pull > /home/grant/nightly-pull.log)'

/home/grant/sbn-git/asterisk/gen-guests.pl > /home/grant/gen-guests.log

asterisk
