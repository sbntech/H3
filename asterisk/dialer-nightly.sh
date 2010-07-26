#!/bin/bash

# nightly asterisk dialer restart

# stop & clear ...
monit stop all
sleep 10
killall -KILL asterisk
killall -KILL AsteriskDialer.pl
rm -rf /var/log/asterisk/*
rm /var/log/AsteriskDialer.*
rm /var/log/astdialer.log
/etc/init.d/monit stop
rm /var/log/monit.log

# update ...
sudo -u grant /bin/bash -c '(cd /home/grant/sbn-git ; git pull > /home/grant/nightly-pull.log)'
/usr/bin/install -o root -g root -m 0600 /home/grant/sbn-git/asterisk/astdialer-monitrc /etc/monit/monitrc

# start ...
/etc/init.d/monit start
sleep 10
monit start all
