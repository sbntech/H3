#!/bin/bash

# nightly restart

killall AsteriskColdCaller.pl
killall AstRecordings.pl
sleep 3
killall asterisk 
sleep 3
killall -KILL AsteriskColdCaller.pl
killall -KILL AstRecordings.pl
sleep 1
killall -KILL asterisk
rm /var/log/asterisk/*
rm /var/log/astcoldcaller.log
rm /var/log/AsteriskColdCaller.pl.*
rm /var/log/AstRecordings.pl.*
rm /var/log/astrecordings.log

sudo -u grant /bin/bash -c '(cd /home/grant/sbn-git ; git pull > /home/grant/nightly-pull.log)'

asterisk
sleep 4

/home/grant/sbn-git/convert/AsteriskColdCaller.pl B
/home/grant/sbn-git/convert/AstRecordings.pl
