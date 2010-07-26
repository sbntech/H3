#!/bin/bash

# first time: aptitude install libncurses-dev
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
		echo 'Removing ald source dir'
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

rm -rf /etc/asterisk
if [ "$HOST" = "w006" -o "$HOST" = "roadrunner" ]
then
	# our "carrier" box
	echo "Carrier config"
	ln -s /home/grant/sbn-git/asterisk/carrier-config /etc/asterisk

	if [ "$HOST" = "w006" ]
	then
		/home/grant/sbn-git/asterisk/gen-guests.pl
	fi
elif [ "$HOST" = "worker2" ]
then
	ln -s /home/grant/sbn-git/asterisk/w2-config /etc/asterisk
	#ln -s /home/grant/sbn-git/asterisk/w2-config/dalong.gsm /var/lib/asterisk/voicemail/sbn/103/unavail.gsm
else
	ln -s /home/grant/sbn-git/asterisk/dialer-config /etc/asterisk

	if [ ! -d /dialer/projects ]
	then
		echo "!!! still need to create and prepare /dialer/projects";
	else
		rm -f /var/lib/asterisk/sounds/projects
		ln -s /dialer/projects /var/lib/asterisk/sounds/projects
	fi
fi

rm -f /var/lib/asterisk/sounds/sbn
ln -s /home/grant/sbn-git/asterisk/sounds /var/lib/asterisk/sounds/sbn

