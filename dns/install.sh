#!/bin/bash

FROM=/home/grant/sbn-git/dns

echo "Installing from $FROM"

for FN in sbndials.zone jannekesmit.zone named.conf.local
do
	echo "Installing $FN"
	install --owner=root --group=bind --mode=0644 $FROM/$FN /etc/bind
done

echo "Restarting"

/etc/init.d/bind9 restart

echo "Done"
