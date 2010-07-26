#!/usr/bin/perl

# populates the various numbercache files

use strict;
use warnings;

use lib '/dialer/www/perl';
use DialerUtils;
use Time::HiRes qw( gettimeofday tv_interval );

my $dbh;
my %demand; # as in $demand{<carrier>}{<PJ_Number>} = lines
$| = 1; # unbuffered output
my $t0 = [gettimeofday()];

# .............................................................................
sub logmsg {
	my ($dt, $tm) = DialerUtils::local_datetime();

	my $t1 = [gettimeofday()];
	my $elapsed = tv_interval($t0, $t1);
	my $m = sprintf('%0.3f', $elapsed);
	$t0  = $t1;

	print "$dt $tm ($m): ";
	print @_;
	print "\n";
}

# .............................................................................
sub loadcache {
	my $carrier  = shift;
	my $cachetbl =  "numberscache_$carrier";

	my $NUMS_PER_LINE = 20;

	PROJECT: for my $pjnum (keys %{$demand{$carrier}}) {
		my $d = $demand{$carrier}{$pjnum};
		if ($d <= 0) {
			logmsg ("ERROR: demand=$d for $pjnum on $carrier");
			next;
		}

		my $cref = $dbh->selectrow_hashref("select count(*) as Size from $cachetbl
			where NC_Project = $pjnum limit 1");
		my $csz = $cref->{'Size'};

		my $tsz = ($d * $NUMS_PER_LINE);
		my $fetch = $tsz - $csz;
		$fetch = 0 if $fetch < 0;

		logmsg("building $cachetbl for project $pjnum which is running on " .
			  "$d lines of $carrier (current_size=$csz, target_size=$tsz, fetching=$fetch)");

		if ($fetch > 0) {
			my $pnTableName = "projectnumbers_$pjnum";
			
			my $res = $dbh->selectrow_hashref(
				"select * from project where PJ_Number = $pjnum");
			my $pn = $dbh->selectrow_hashref(
				"select count(*) as pnSize from $pnTableName");
			my $pnSize = $pn->{'pnSize'};

			if (! defined($res)) {
				warn "dialnumbers: project number $pjnum is unfound";
				next;
			}

			my $tzones = DialerUtils::timezones_allowed(
				$res->{'PJ_Local_Time_Start'},
				$res->{'PJ_Local_Start_Min'},
				$res->{'PJ_Local_Time_Stop'},
				$res->{'PJ_Local_Stop_Min'});


			my $zone_predicate = '(';
			my $sep = '';
			for my $tz (@$tzones) {
				$zone_predicate .= "$sep PN_TimeZone = $tz";
				$sep = " or";
			}
			$zone_predicate .= ')';
			if ($zone_predicate eq '()') {
				logmsg("Project $pjnum not active in any timezones, skipping");
				next PROJECT;
			}

			$dbh->do("create temporary table workcache (Num char(10)) Engine = MEMORY");
			my $needed = $fetch;
			my $fcount = 0; # found count

			# BestCarriers
			$dbh->do(
				"insert into workcache select PN_PhoneNumber from $pnTableName
				where PN_Status = 'R' and
				$zone_predicate and instr(PN_BestCarriers, '$carrier') > 0
				order by PN_Seq limit $needed");

			my $nres = $dbh->selectrow_hashref("select count(*) as RowsCount
				from workcache");
			$fcount = $nres->{'RowsCount'};
			$needed = $fetch - $fcount;
			logmsg("$cachetbl selected $fcount BestCarrier rows into workcache for project $pjnum  (still need $needed rows)");

			# AltCarriers
			if ($needed > 0) {
				$dbh->do(
					"insert into workcache select PN_PhoneNumber from $pnTableName
					where PN_Status = 'R' and
					$zone_predicate and instr(PN_AltCarriers, '$carrier') > 0
					order by PN_Seq limit $needed");

				$nres = $dbh->selectrow_hashref("select count(*) as RowsCount
					from workcache");
				my $altcount = $nres->{'RowsCount'} - $fcount; # current rows minus best rows
				$fcount = $nres->{'RowsCount'}; 
				$needed = $fetch - $fcount;

				logmsg("$cachetbl selected $altcount AlternateCarrier rows into workcache for project $pjnum (still need $needed rows)");
			}

			if ($fcount > 0) {
				# workcache has something
				my $cached = $dbh->do(
						"insert ignore into $cachetbl (NC_Project, NC_PhoneNumber)
						select '$pjnum', Num from workcache");
				if ($cached == 0) {
					logmsg("cache insert failed: " . $dbh->errstr);
				}
				logmsg("$cachetbl: $cached rows inserted for project $pjnum");


				my $updated = $dbh->do("update $pnTableName, workcache
					set PN_Sent_Time = now(), PN_Status = 'C'
					where PN_PhoneNumber = Num");
				if ($updated == 0) {
					logmsg("failed to update $pnTableName: " . $dbh->errstr);
				}

				logmsg("$pnTableName: $updated rows updated for project $pjnum");
			} else {
				logmsg("failed to load anything into $cachetbl for project $pjnum (still need $needed rows)");
			}

			$dbh->do("drop table workcache");
		}
	}
}


# .............................................................................
sub emptycache {
	my $carrier  = shift;
	my $cachetbl =  "numberscache_$carrier";

	my $ref = $dbh->selectall_arrayref("select NC_Project,
		count(*) as NumCount from $cachetbl
		group by NC_Project", { Slice => {}});

	for my $pjrow (@$ref) {
		my $pjnum = $pjrow->{'NC_Project'};

		next if ((defined($demand{$carrier}{$pjnum})) &&
			($demand{$carrier}{$pjnum} > 0));

		logmsg("Project $pjnum has no allocation on carrier $carrier, empty the cache!");

		my $pnTableName = "projectnumbers_$pjnum";

		my $returned = $dbh->do("update $pnTableName, $cachetbl 
			set PN_Sent_Time = null, PN_Status = 'R'
			where PN_PhoneNumber = NC_PhoneNumber
				and NC_Project = $pjnum
				and PN_Status != 'X'");

		my $cachesize = $dbh->do("delete from $cachetbl where NC_Project = $pjnum");

		logmsg("$returned numbers returned to $pnTableName, cachesize was $cachesize numbers");
	}
}

# .............................................................................
for my $prog (`ps -o pid= -C number-helper.pl`) {
	if ($prog != $$) {
		die "Not continuing, number-helper already running with pid=$prog";
	}
}

DialerUtils::daemonize();
open(PID, ">", "/var/run/number-helper.pid");
print PID $$;
close(PID);
print("\n\nstarts with pid $$\n");
warn("\nstarts with pid $$");


$dbh = DialerUtils::db_connect(); # connect to the database
for my $c ('A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I') {
	$dbh->do("create table if not exists numberscache_$c like numberscache");
}
$dbh->disconnect;

# .............................................................................
my $infile = '/root/number-helper.input';

while (1) {
	logmsg("- - - - - - - - - - - -");
	$dbh = DialerUtils::db_connect(); # connect to the database

	logmsg("waiting for input");
	while (! -f $infile) {
		sleep 2;
	}

	# ... determine current demand
	unless (open NH, '<', $infile) {
		logmsg("failed to open $infile: $!");
		next;
	}

	for my $c ('A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I') {
		$demand{$c} = ();
	}
	while (<NH>) {
		my ($pjnum,$carr,$alloc) = split /:/;
		if ($alloc > 0) {
			$demand{$carr}{$pjnum} += $alloc; 
		}
	}
	close(NH);
	unlink($infile);
	logmsg("loaded distribution from $infile");

	# ... load the caches
	for my $c (keys %demand) {
		loadcache($c);
		emptycache($c);
	}

	$dbh->disconnect;
	sleep 1;
}
