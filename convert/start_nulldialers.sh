#!/bin/bash

NVRIP=10.10.10.6

rm /var/log/nulldialer-*
killall nulldialer.pl

for D in 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 23 24 25 26
do
	/dialer/convert/nulldialer.pl $D $NVRIP &
done
