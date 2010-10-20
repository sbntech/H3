#!/usr/bin/perl

use strict;
use warnings FATAL => 'all';
use lib '/home/grant/H3/www/perl/';
use DialerUtils;
use DateTime;

my $dbh = DialerUtils::db_connect();
my %Totals;

my $fromDT = DateTime->new(year => 2009, month => 10, day => 1);
my $toDT   = DateTime->new(year => 2011, month => 1, day => 1);

# open the mine file
open(MINED, '>', "/home/grant/Carl-Fix.csv") || die "Failed to open output file: $!";
print MINED "Project,PJ_Description,CO_Number,CO_Name,ResId,Year,Month,Seconds,Minutes\n";

my $res = $dbh->selectall_arrayref("select 
	PJ_Number, CO_Number, CO_ResNumber, PJ_Description, CO_Name 
	from project,customer 
	where PJ_CustNumber = CO_Number and PJ_Type = 'C'
		and (CO_ResNumber = 79)",
	{ Slice => {}});

PROJECT: for my $row (@$res) {

	printf "Project: %d - %s for customer %d (%s) is being processed:\n", $row->{'PJ_Number'}, $row->{'PJ_Description'}, $row->{'CO_Number'}, $row->{'CO_Name'};
	my $pjdir = "_" . $row->{'PJ_Number'};
	my %ROW;

	FILE: foreach my $file (`find /dialer/projects -wholename "/dialer/projects/$pjdir/cdr/cdr-*"`) {
		chomp $file;
		my ($fPJ, $fYear, $fMonth, $fDay, $fExt);

		if ($file =~ /\/dialer\/projects\/_(\d*)\/cdr\/cdr-(20\d\d)-(\d\d)-(\d\d)\.(zip|txt)/) {
			($fPJ, $fYear, $fMonth, $fDay, $fExt) = ($1, $2, $3, $4, $5);
		} else {
			die "$file has unrecognized format";
		}

		# check if the day is between our dates
		my $fDT = DateTime->new(year => $fYear, month => $fMonth, day => $fDay);
		next FILE if (
			(DateTime->compare($fDT, $fromDT) < 0) || # file datetime is before fromDT
			(DateTime->compare($fDT, $toDT) > 0));    # file datetime is after toDT

		# open the cdr file
		if ($fExt eq 'zip') {
			if (! open(DATA, "unzip -p '$file'|")) {
				die "Failed to open $file: $!";
			}
		} else {
			open(DATA, '<', $file) || die "Failed to open $file: $!";
		}

		print "  > reading file $file ... \n";

		CDR: while(my $line=<DATA>)
		{
			my $cdr = DialerUtils::sbncdr_parser($line);
			if (!defined($cdr)) {
				print "skipping unparsable cdr $line";
				next CDR;
			}

			if ((substr($cdr->{'CalledNumber'},5,5) eq '00000') && ($cdr->{'Duration'} > 0)) {
				my $s6 = int(($cdr->{'Duration'} - 1 + 6) / 6) * 6;
				$ROW{$fYear}{$fMonth} += $s6;
				$Totals{"$fYear-$fMonth"} += $s6;
			}
		}
		close(DATA);
	}

	my $pre = sprintf "%d,%s,%d,%s,%d", $row->{'PJ_Number'}, $row->{'PJ_Description'}, $row->{'CO_Number'}, $row->{'CO_Name'}, $row->{'CO_ResNumber'};

	for my $yr (sort keys %ROW) {
		for my $mnth (sort keys %{$ROW{$yr}}) {
			my $row = $ROW{$yr}{$mnth};
			print MINED "$pre,$yr,$mnth,$row," . sprintf("%0.1f", $row/60) . "\n";
		}
	}

}
	
$dbh->disconnect;

print MINED "\n\n\nTotals,Seconds,Minutes\n";
for my $k (sort keys %Totals) {
	my $secs = $Totals{$k};
	printf MINED "%s,%d,%0.1f\n", $k, $secs, $secs/60;
}

close(MINED);
