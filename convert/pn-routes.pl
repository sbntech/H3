#!/usr/bin/perl

use strict;
use warnings FATAL => 'all';

use lib '/home/grant/H3/www/perl';
use DialerUtils;
use DBI;
use lib '/home/grant/H3/convert/npanxx-data';
use Rates;
$|=1;

my $dbh = DialerUtils::db_connect(); # connect to the database

my $r = initialize Rates(1);
my $running = 2;
my $restart = 1000000;

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

	my $pick = $dbh->selectrow_hashref("select * from temp_routing
		where TR_Flag is null order by TR_Seq desc, TR_Rows limit 1");

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

	my $ci = $dbh->selectrow_hashref("select PJ_CustNumber, CO_ResNumber, PJ_Description, CO_Name
		from project, customer where PJ_CustNumber = CO_Number and PJ_Number = $pjnum limit 1");

	printf "$pjnum (%s for %s-%s) [$rowcount rows est.]\n", 
		$ci->{'PJ_Description'}, $ci->{'PJ_CustNumber'}, $ci->{'CO_Name'};

	my $stmt = $dbh->prepare("select * from $tblname");
	$stmt->execute();
	my $changes = 0;
	my $scrubbed = 0;
	my $rowsread = 0;
	my $curptr = 0;

	my $pn;
	while (($running > 0) && ($pn = $stmt->fetchrow_hashref())) {
		$rowsread++;
		if ($curptr < 100 * ($rowsread / $rowcount)) {
			print ".";
			$curptr++;
		}
		my $number = $pn->{'PN_PhoneNumber'};
		my $nn = $r->lookup_number($number, $ci->{'PJ_CustNumber'}, $ci->{'CO_ResNumber'});


		my $OldAlt;
		if ((defined($pn->{'PN_AltCarriers'})) && (length($pn->{'PN_AltCarriers'}) > 0)) {
			$OldAlt = "'" . $pn->{'PN_AltCarriers'} . "'";
		} else {
			$OldAlt = 'null';
		}

		my $StatusClause = "PN_Status = 'X', PN_CallResult = 'XR', "; # unroutable (default)
		if ((defined($nn)) && ($nn->{'Routable'} == 1)) {
			# routable ...
			if ((defined($nn->{'ScrubType'})) && (length($nn->{'ScrubType'}) == 2)) {
				# ... but scrubbed
				$StatusClause = "PN_Status = 'X', PN_CallResult = '" . $nn->{'ScrubType'} . "', ";
				$scrubbed++;
			} else {
				# ... not scrubbed
				$StatusClause = '';
			}
		}

		my $AltCarriers = 'null';
		if (length($nn->{'AltCarriers'}) > 0) {
			$AltCarriers = "'" . $nn->{'AltCarriers'} . "'";
		}

		if (($pn->{'PN_BestCarriers'} ne $nn->{'BestCarriers'}) || ($OldAlt ne $AltCarriers) || (length($StatusClause) > 0)) {
			$changes++;
			$dbh->do("update $tblname set $StatusClause
					PN_BestCarriers = '" . $nn->{'BestCarriers'} . "', 
					PN_AltCarriers = $AltCarriers
					where PN_PhoneNumber = '$number'");
		}
	}
	$stmt->finish();

	if ($rowsread > 0) {	
		printf "\nProject: $pjnum (%s for %s-%s) [$rowsread rows] had $changes (%d%%) rows updated, $scrubbed numbers scrubbed (%0.1f%%). (Restarting in %d rows time)\n", $ci->{'PJ_Description'}, $ci->{'PJ_CustNumber'}, $ci->{'CO_Name'}, int(100*$changes/$rowsread), 100*$scrubbed/$rowsread, $restart;
		$restart -= $rowsread;
	}

	$dbh->do("delete from temp_routing where TR_Project = $pjnum limit 1");

	last if $restart < 0;
}

my $stats = $dbh->selectrow_hashref("select (select count(*) from temp_routing) as Projects, (select sum(TR_Rows) from temp_routing) as Rows");

my $pleft = $stats->{'Projects'};
my $rleft = $stats->{'Rows'};

$dbh->disconnect;

if ($pleft == 0) {
	print "Finished.\n";
	exit;
} elsif ($running == 2) {
	print "Restarting [[[ $pleft projects and $rleft rows left to do ]]]\n";
	exec("/home/grant/H3/convert/pn-routes.pl");
}
