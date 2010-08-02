#!/usr/bin/perl

use strict;
use warnings;

use lib '/home/grant/H3/www/perl/';
use DialerUtils;
use CDB_File;
use Time::HiRes qw( gettimeofday tv_interval );
my $t0 = [gettimeofday()];
$|=1;

my $running = 2;
my $cdbdir = '/dialer/maindnc';
if (! -d $cdbdir) {
	die "ERROR: missing maindnc dir $cdbdir containing cdb data";
}

my $dbh = DialerUtils::db_connect();
my $sbn2 = DialerUtils::sbn2_connect();

$dbh->do("create temporary table dnc_rescrub (DNC_Phone char(10) not null, primary key (DNC_Phone))"); 

sub exit_handler {
	if ($running == 2) {
		print("\nsignal caught: stopping after this project\n");
		$running = 1;
	} else {
		print("\nsignal caught: stopping NOW!\n");
		$running = 0;
	}
}

$SIG{INT} = \&exit_handler;
$SIG{QUIT} = \&exit_handler;
$SIG{TERM} = \&exit_handler;


while ($running > 1) {

	# does old projects first
	my $pick = $dbh->selectrow_hashref("select * from temp_routing
		where TR_Flag is null order by TR_Seq, TR_Rows limit 1");

	unless (defined($pick->{'TR_Project'})) {
		print "Finished\n";
		exit; # cannot do "last" 'cos of the exec
	}

	my $cnt = $dbh->do("update temp_routing set TR_Flag = 'Y' 
		where TR_Flag is null and TR_Project = '" .
		$pick->{'TR_Project'} . "'");

	if ($cnt <= 0) {
		print "Collision, trying again\n";
		next;
	}

	my $pjnum = $pick->{'TR_Project'};
	my $tblname = "projectnumbers_$pjnum";
	my $rowcount = $pick->{'TR_Rows'};

	print "starting project $pjnum with $rowcount rows\n";

	# read projectnumbers_99999 split by prefix (first 2 digits)
	my $sth = $dbh->prepare("select PN_PhoneNumber from $tblname
		where PN_Status != 'X' order by substr(PN_PhoneNumber,1,2)");
	die "failed to get numbers for project $pjnum" unless $sth->execute;

	my $prefix = "00";

	# build a DNC subset in the temp table
	my %DNC;
	my $found = 0;
	my $total = 0;
	while (my $row = $sth->fetchrow_hashref()) {
		my $rfix = substr($row->{'PN_PhoneNumber'},0,2);
		my $sfix = substr($row->{'PN_PhoneNumber'},2,12);

		my $scrub_it = 0;
		$total++;

		if ($rfix ne $prefix) {
			untie %DNC;
			$prefix = $rfix;
			if (-f "$cdbdir/$prefix.cdb") {
				tie (%DNC, 'CDB_File', "$cdbdir/$prefix.cdb") or die "tie failed for $cdbdir/$prefix.cdb: $!";
			} else {
				$prefix = "00";
				next;
			}
		}
					
		if (defined($DNC{$sfix})) {
			$scrub_it = 1;
		} else {
			# check the custdnc
			my $res = $sbn2->selectrow_hashref("select CD_PhoneNumber from custdnc
				where CD_PhoneNumber = '" . $row->{'PN_PhoneNumber'} . "' and
				CD_LastContactDT > date_sub(now(), interval 3 month)");
			if (defined($res->{'CD_PhoneNumber'})) {
				$scrub_it = 1;
			}
		}

		if ($scrub_it == 1) {
			$found++;
			$dbh->do("insert into dnc_rescrub values (" . $row->{'PN_PhoneNumber'} . ")");
		}
	}

	untie %DNC;

	# then update projectnumbers_99999
	my $scrubbed = $dbh->do("update projectnumbers_$pjnum set PN_Status = 'X' 
		where exists(select 'x' from dnc_rescrub where DNC_Phone = PN_PhoneNumber)");

	$dbh->do("truncate table dnc_rescrub");

	my ($dt, $tm) = DialerUtils::local_datetime();
	my $t1 = [gettimeofday()];
	my $elapsed = tv_interval($t0, $t1);
	my $m = sprintf('%0.3f', $elapsed);
	$t0 = $t1;
	my $perc = '';
	if ($total > 0) {
		$perc = sprintf('%0.1f', 100 * ($scrubbed / $total));
	}
	print "$dt $tm (Elapsed=$m): Project $pjnum had $found scrubbable numbers" .
				" and $scrubbed were actually scrubbed. ($perc%)\n";

	$dbh->do("delete from temp_routing where TR_Project = $pjnum limit 1");

	my $stats = $dbh->selectrow_hashref("select (select count(*) from temp_routing) as Projects, (select sum(TR_Rows) from temp_routing) as Rows");
	my $pleft = $stats->{'Projects'};
	my $rleft = $stats->{'Rows'}; $rleft = 0 unless defined $rleft;

	print "To-Do: $pleft projects and $rleft rows\n";
}

$dbh->do("drop temporary table dnc_rescrub");
$dbh->disconnect;
$sbn2->disconnect;
