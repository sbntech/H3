#!/bin/bash
# insert into phones (PH_Number, PH_CarrierA, PH_CarrierF) values (9494542348, 0.007, 0.005);
# insert into phones (PH_Number, PH_CarrierA, PH_CarrierF) values (3473669060, null, 0.015);

# nulldialer|astdialer|coldcaller
DIALERTYPE=$1

function stop_mysql {

	echo "Stopping mysql ..."
	rm /etc/cron.d/GLM-backup-mysql
	#service mysql stop
	killall mysqld
	sleep 1
	killall -KILL mysqld

	echo "... Removing mysql logs"
	rm /var/log/mysql.*

	echo "... Unmounting tempfs on /var/lib/mysql"
	umount /var/lib/mysql
	echo "... Deleting any straggling data - should be nothing"
	find /var/lib/mysql -mindepth 1 -delete
	echo "= = = = = = mysql stopped"
}

function start_mysql {

	echo "Preparing mysql ..."
	echo "removing mysql log files ..."
	rm -r /var/log/mysql/*
	echo "... Mounting tempfs on /var/lib/mysql"
	mount -t tmpfs -o size=400M,mode=755,uid=mysql,gid=mysql mysql_tmpfs /var/lib/mysql
	echo "... Copying database data"
	rsync -aH /root/mysql/ /var/lib/mysql/

	echo "Starting mysql ..."
	#service mysql start
	mysqld_safe &

	echo ".. showing outcome"
	ps -ef | grep mysql
	echo
	df -h | grep mysql
	echo
	ls /var/lib/mysql

	echo "= = = = = = mysql started"
	echo "*/5 * * * * root rsync -aq /var/lib/mysql/ /root/mysql" > /etc/cron.d/GLM-backup-mysql
}

function stopall {
	echo "Stopping..."

	echo "dialer cronjobs..."
	rm /etc/cron.d/GLM-dialer

	echo "AsteriskColdCaller..."
	killall AsteriskColdCaller.pl
	sleep 5
	killall -KILL AsteriskColdCaller.pl

	echo "AstRecordings..."
	killall AstRecordings.pl
	sleep 1
	killall -KILL AstRecordings.pl

	echo "AsteriskDialer..."
	killall AsteriskDialer.pl
	sleep 5
	killall -KILL AsteriskDialer.pl

	echo "nulldialer" ; killall -KILL nulldialer.pl
	echo "nvr" ; killall nvr2.pl
	echo "asterisk"
	killall asterisk
	sleep 1
	killall -KILL asterisk
	echo "FastAgiServer.pm"
	/usr/bin/killall FastAgiServer.pm
	sleep 5
	/usr/bin/killall -KILL FastAgiServer.pm
	echo "allocator" ; killall allocator.pl
	echo "number-helper" ; killall number-helper.pl
	echo "CallResultProcessing" ; killall CallResultProcessing.pl
	echo "LoadLeads" ; killall LoadLeads.pl
	sleep 2 # allow the CallResults to be sent by nvrs for processing
	echo "apache2" ; /etc/init.d/apache2 stop
	sleep 2
	ps -ef | grep 'perl\|asterisk\|apache'
	echo "... all stopped"
}

function rm_logs {
	echo "Removing log files ..."
	rm -f /var/log/nulldial*
	rm -f /var/log/nvr*
	rm -f /var/log/LoadLeads*
	rm -f /home/www-data/cdr-alarm.txt
	rm -f /home/www-data/NumbersUpload*
	rm -f /dialer/www/status/allocator.html
	rm -f /dialer/www/status/result-stats.html
	rm -f /dialer/www/fancy/*
	rm -f /var/log/apache2/*
	rm -f /var/log/allocator*
	rm -f /var/log/number-helper*
	rm -f /root/number-helper*
	rm -f /var/log/CallResultProcessing*
	rm -f /var/log/ast*
	rm -f /var/log/AstRecordings*
	rm -f /var/spool/asterisk/monitor/*
	rm -f /var/log/Asterisk*
	rm -f /var/log/asterisk/*
	rm -f /var/log/FastAgiServer.log

	echo "Clearing call-results-queue ... "
	rm -f /dialer/call-results-queue/*

	echo "Clearing /dialer/projects/workqueue ... "
	rm -f /dialer/projects/workqueue/*

	echo "Deleting old cdrs ... "
	find /dialer/projects -wholename '*/cdr/cdr-20*' -delete

	echo "truncating table switch ..."
	echo "truncate table switch" | mysql -psbntele dialer

	echo "logging off agents ..."
	echo "update agent set AG_SessionId = null, AG_QueueReady = 'N', AG_Paused = 'N', AG_Lst_change = now()" | mysql -psbntele dialer
}

if [ `hostname` = 'swift' ]
then
	echo We are swift
else
	echo Only run on swift
	exit;
fi

case $1 in
	("mysqlstop")
		stop_mysql
		;;
	("mysql")
		# the start should have failed because the mount point is empty,
		# but just in case ...
		stop_mysql
		start_mysql
		;;
	("stop")
		stopall
		;;
	(*)
		stopall
		rm_logs
		echo "Starting..."
		cd /dialer/convert

		# make the test environment use America/New_York
		export TZ='America/New_York' 

		# reset some things - so it is like a brand new day
		echo "hourly-dbupdates..."
		./hourly-dbupdates.pl "interval 1 second"
		echo "nightly jobs..."
		./nightly-ap.pl
		./nightly-db0.pl

		# start the LoadLeads.pl
		./LoadLeads.pl 5

		echo -e "* * * * * root /home/grant/H3/convert/voiceprompts-rsync.sh"  > /etc/cron.d/GLM-dialer

		if [ "$DIALERTYPE" = "astdialer" ]
		then
			echo "starting AsteriskDialer.pl"
			/home/grant/H3/convert/AsteriskDialer.pl
			sleep 1
			echo "update switch set SW_VoipCPS = 10, SW_VoipPorts = 300 where SW_ID = 'WTST'" | mysql -psbntele dialer
			echo "update line set ln_status = 'F' where ln_status = 'B' and ln_switch = 'WTST' limit 300" | mysql -psbntele dialer
		elif [ "$DIALERTYPE" = "coldcaller" ]
		then
			echo "starting AsteriskColdCaller.pl"
			/home/grant/H3/convert/AstRecordings.pl
			/home/grant/H3/convert/AsteriskColdCaller.pl Z
			/home/grant/H3/convert/AstAgentsGen.pl
		elif [ "$DIALERTYPE" = "nulldialer" ]
		then
			CARRIER[201]="A"
			CARRIER[202]="F"
			for NVRIP in 202 201
			do
				echo "nvr $NVRIP" 
				./nvr2.pl 127.0.0.$NVRIP ${CARRIER[$NVRIP]} localhost & 
				sleep 1;
				echo "nulldialer $NVRIP" 
				./nulldialer.pl $NVRIP 127.0.0.$NVRIP 127.100.0.$NVRIP &
			done
		fi

		sleep 3 ; 
		echo "number-herlper.pl"
		./number-helper.pl
		echo "allocator.pl"
		./allocator.pl
		echo "CallResultProcessing.pl"
		./CallResultProcessing.pl
		echo "FastAgiServer.pm"
		./FastAgiServer.pm

		;;
esac
