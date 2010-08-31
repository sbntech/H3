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

sudo -u grant /bin/bash -c '(cd /home/grant/H3 ; git pull > /home/grant/nightly-pull.log)'

asterisk
sleep 4

/home/grant/H3/convert/AsteriskColdCaller.pl A
/home/grant/H3/convert/AstRecordings.pl
