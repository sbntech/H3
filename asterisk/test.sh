#!/bin/bash

rm /root/tcp-raw.dump
asterisk -r -x 'logger rotate'
asterisk -r -x 'module reload'
rm /var/log/asterisk/*.0
rm /var/log/astdialer.*
rm /var/spool/asterisk/monitor/*
sleep 2
echo "Asterisk: logs rotated and modules reloaded."

echo "Starting tcpdump for SIP traces..."
set -m # man bash; allows background processes to be in their own process group
tcpdump -i eth0 -s 0 -w /root/tcp-raw.dump port 5060 & 

echo "Running the dialer now..."
/home/grant/H3/convert/AsteriskDialer.pl > /var/log/astdialer.out 2>&1
echo "dialer exits"

killall tcpdump
DATESTR=`date +%Y%m%d-%Hh%Mm%Ss`
DATESTR="latest"
rm /home/grant/run-$DATESTR.zip
zip -j /home/grant/run-$DATESTR.zip /var/log/asterisk/verbose /var/log/asterisk/debug /root/tcp-raw.dump /var/log/astdialer.* /var/spool/asterisk/monitor/*-in.ulaw 
