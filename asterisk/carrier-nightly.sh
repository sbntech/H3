#!/bin/bash

# nightly asterisk carrier refresh
# w6 is the carrier

monit stop asterisk
sleep 1
killall -KILL asterisk
rm -rf /var/log/asterisk/*

sudo -u grant /bin/bash -c '(cd /home/grant/H3 ; git pull > /home/grant/nightly-pull.log)'

/home/grant/H3/asterisk/gen-guests.pl > /home/grant/gen-guests.log

monit start asterisk
