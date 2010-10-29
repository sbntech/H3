#!/bin/bash

echo "Called with $1 $2" >> /home/www-data/ssl.log
DOMAIN=$1

case $DOMAIN in
	"secure.bullseyebroadcast.com:4431")
		# key of 2009-05-26 is not actually encrypted
		echo -n 'Leadpower1'
	;;
	"secure.quickdials.com:443")
		echo -n 'ssl-sam'
	;;
	*)
		echo -n 'no such luck'
	;;
esac
	
