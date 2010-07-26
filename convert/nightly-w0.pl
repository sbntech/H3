#!/usr/bin/perl

use strict;
use warnings;

use lib '/dialer/www/perl';
use DialerUtils;
use Time::HiRes qw( gettimeofday tv_interval );

# connect to the database
my $dbh = DialerUtils::db_connect(); 

# remove any dangling agent sessions
system("rm -f /dialer/www/popup/*");

# remove any temp files used for number file downloading
system("rm -f /tmp/NF-*.zip");

# clean up the agents, just in case
$dbh->do("update agent set AG_QueueReady = 'N', 
			AG_BridgedTo = null, 
			AG_SessionId = null");

# clean some daily call results things
unlink("/dialer/www/status/block-log.txt");
unlink("/dialer/www/status/anomaly-log.txt");
unlink("/dialer/www/status/call-results-stats.json");
unlink("/dialer/www/fancy/allocator.graph.json");
unlink("/dialer/www/fancy/cdr.graph.json");
system("rm /dialer/www/fancy/projplot-*");

# ---------------
$dbh->do("update switch set SW_callsday = 0");
$dbh->do("update project set PJ_timeleft = 'Deleted' where PJ_Visible = 0");

if (`hostname` =~ /worker0/) { # on swift we don't want this
	# move non-connect files to db0
	system("scp -q /root/NonConnectedNumber.txt 10.9.2.15:/root/");
	unlink("/root/NonConnectedNumber.txt");
	system("scp -q /root/BadNumber.txt 10.9.2.15:/root/");
	unlink("/root/BadNumber.txt");
}

# ---------------
# clean support messages
$dbh->do("delete from support where SU_DateTime < 
	date_sub(now(), interval 14 day)");

# ---------------
# restart apache

system("/etc/init.d/apache2 stop");
system("rm -rf /var/log/apache2/*");
system("/etc/init.d/apache2 start");


# ---------------

my $res = $dbh->selectall_arrayref("show table status 
	where name like 'projectnumbers_%'", { Slice => {}});

for my $row (@$res) {
	my $tbl = $row->{'Name'};
	my ($nowdt, $nowtm) = DialerUtils::local_datetime();
	my $t0 = [gettimeofday()]; # benchmark timer starts

	# clear the cached numbers
	# (since hourly_dbupdates might miss some when the day changes)
	my $cnt = $dbh->do("update $tbl
		set PN_Sent_Time = null, PN_Status = 'R'
		where PN_Sent_Time < date_sub(now(), interval 20 minute) 
			and PN_Status != 'X' and PN_Status != 'R'");

	if ($cnt > 0) {
		print("$tbl updated $cnt rows that were stuck in the cache\n");
	}

	if (
		($tbl eq 'projectnumbers_44356') || # newdeal-ALL
		($tbl eq 'projectnumbers_46584') || # newdeal-ALL2
		($tbl eq 'projectnumbers_44311') # LVVA-companyfunds
		) {
		# new deal get special treatment
		my $days = 10;
		$days = 3 if $tbl eq 'projectnumbers_46584'; # ALL2

		my $dels = $dbh->do("delete quick from $tbl where (PN_DoNotCall = 'Y' or (PN_Agent > 0 and PN_Agent != 9999))");
		print "deleted $dels DNC/P1 rows from $tbl\n";

		my $aff = $dbh->do("update $tbl set PN_Status = 'R',
			PN_Seq = PN_Seq + floor(rand()*100000)
			where PN_Status = 'X' and PN_DoNotCall != 'Y'
			and date_sub(now(), interval $days day) > PN_CallDT ");

		$aff = 0 unless $aff;
		printf("%d live numbers reset for redialing\n", $aff);

	}
	
	if ($row->{'Rows'} == 0) {  
		# drop empty tables like projectnumbers_99999
		print "dropping $tbl it has no rows\n";
		$dbh->do("drop table $tbl");
	} else {
		print "$nowdt $nowtm : deleting rows marked for deletion in $tbl\n";
		my $dels = $dbh->do("delete quick from $tbl where PN_Status = 'X'
			and PN_Popdata is null and PN_CallDT < date_sub(now(), interval 30 day) ");
		print "deleted $dels rows from $tbl \n";

		print "optimizing $tbl\n";
		$dbh->do("optimize table $tbl");

		my $elapsed = tv_interval($t0, [gettimeofday()]);
		print "done with $tbl in $elapsed\n";
	}
}

$dbh->disconnect;

