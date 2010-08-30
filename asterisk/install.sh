#!/bin/bash

CARRIERHOST="w006"
MSGRECHOST="worker2"

ASTVER=$1
echo Installing asterisk version: $ASTVER

ASTSRC="asterisk-$ASTVER"
HOST=`hostname`;

cd /usr/src

if [ "$ASTVER" = "svn" ]
then
	if [ -d /usr/src/asterisk-svn ]
	then
		cd /usr/src/asterisk-svn/asterisk
		svn update
	else
		mkdir /usr/src/asterisk-svn
		cd /usr/src/asterisk-svn
		svn checkout http://svn.digium.com/svn/asterisk/trunk asterisk
		cd /usr/src/asterisk-svn/asterisk
	fi
else
	if [ ! -f /usr/src/$ASTSRC.tar.gz ]
	then
		wget http://downloads.digium.com/pub/asterisk/releases/$ASTSRC.tar.gz
	else
		echo "Not downloading $ASTSRC it is already here."
	fi

	if [ -d /usr/src/$ASTSRC ]
	then
		echo 'Removing old source dir'
		rm -r /usr/src/$ASTSRC
	fi

	tar zxvf "$ASTSRC.tar.gz"

	cd /usr/src/$ASTSRC
fi

rm -f menuselect.makeopts
#make menuselect # for EXTRA-SOUNDS-EN-GSM

./configure --disable-xmldoc || exit
make -j8 || exit
make install || exit

echo "Stock asterisk installed, updating config ..."

rm -rf /etc/asterisk
if [ "$HOST" = "$CARRIERHOST" ]
then
	echo " ... carrier config"
	ln -s /home/grant/H3/asterisk/carrier-config /etc/asterisk
	/home/grant/H3/asterisk/gen-guests.pl
elif [ "$HOST" = "$MSGRECHOST" ]
then
	echo " ... message recording w2-config"
	ln -s /home/grant/H3/asterisk/w2-config /etc/asterisk
else
	echo " ... dialer (or coldcaller) config"
	ln -s /home/grant/H3/asterisk/dialer-config /etc/asterisk

	if [ ! -d /dialer/projects ]
	then
		echo "!!! still need to create and prepare /dialer/projects";
	else
		rm -f /var/lib/asterisk/sounds/projects
		ln -s /dialer/projects /var/lib/asterisk/sounds/projects
	fi
fi

rm -f /var/lib/asterisk/sounds/sbn
ln -s /home/grant/H3/asterisk/sounds /var/lib/asterisk/sounds/sbn

