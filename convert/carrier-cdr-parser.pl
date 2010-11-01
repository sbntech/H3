#!/usr/bin/perl

use strict;
use warnings FATAL => 'all';
use lib '/home/grant/H3/www/perl/';
use DialerUtils;
use DateTime;

$| = 1; # unbuffered output

# <YYYY-MM-DD><CarrierID><Connects|Duration|NonConnects>
my %stats;
my %statsUTC;

my $days = $ARGV[0] || 5;
print "Reporting for last $days days\n";
my $bigcsv;
my $csvhdr;

sub cdr_print {
	my $cdr = shift;
	print 
		$cdr->{'sbn_date'} . ',' .
		$cdr->{'sbn_time'} . ',' .
		$cdr->{'sbn_duration'} . ',' .
		$cdr->{'sbn_called'} . ',' .
		$cdr->{'sbn_cost'} . ',' .
		$cdr->{'sbn_i'} . ',' .
		$cdr->{'State Called'} .
		"\n"
}

sub cdr_dump {
	my $cdr = shift;

	for my $k (sort keys %$cdr) {
		my $val = $cdr->{$k};

		if (defined($val)) {
			printf '%-40s', $k;
			print ": $val\n";
		}
	}
}

sub cdr_read {
	my $DAY = shift;
	my $fday = substr($DAY,0,4) . '-' . substr($DAY,4,2) . '-' . substr($DAY,6,2);

	print "reading cdrs for $DAY ...\n";
	
	foreach my $file (`find /dialer/projects -wholename "/dialer/projects/*/cdr/cdr-$fday.zip"`) {
		chomp $file;
		my $pjid = $file;
		$pjid =~ s/.*_(\d*)\/cdr\/cdr-\d\d\d\d-\d\d-\d\d\.zip/$1/;

		print "$fday:  project $pjid ...\n";

		if (! open(DATA, "unzip -p '$file'|")) {
			die "Failed to open $file: $!";
		}

		while (my $line=<DATA>) {
			my $cdr = DialerUtils::sbncdr_parser($line);

			die "unparsable cdr $line" unless defined ($cdr);

			# determine if it counts as a connect 
			my $conn = 1;
			if ($cdr->{'Dialer'} eq 'COLD') {
				$conn = 0 if ($cdr->{'Disposition'} eq 'AC');
				$conn = 0 if ($cdr->{'Disposition'} eq 'AS') &&
							 ($cdr->{'CallSetup'} ne 'Standby-OFF');
			}

			# billing/rating
			my $rdur = 0;
			if ($cdr->{'Duration'} > 0) {
				my $m = 0;
				if ($cdr->{'Duration'} % 6 > 0) {
					$m = 6 - ($cdr->{'Duration'} % 6);
				}
				$rdur = $cdr->{'Duration'} + $m;

				# store the stats
				$stats{$cdr->{'Date'}}{$cdr->{'CarrierCode'}}{'Connects'} += $conn;
				$stats{$cdr->{'Date'}}{$cdr->{'CarrierCode'}}{'Duration'} += $rdur;
				$stats{$cdr->{'Date'}}{'TOTAL'}{'Connects'} += $conn;
				$stats{$cdr->{'Date'}}{'TOTAL'}{'Duration'} += $rdur;
				
				$stats{$cdr->{'DateUTC'}}{$cdr->{'CarrierCode'}}{'Connects'} += $conn;
				$stats{$cdr->{'DateUTC'}}{$cdr->{'CarrierCode'}}{'Duration'} += $rdur;
				$stats{$cdr->{'DateUTC'}}{'TOTAL'}{'Connects'} += $conn;
				$stats{$cdr->{'DateUTC'}}{'TOTAL'}{'Duration'} += $rdur;
			} else {
				# non-connect stats
				$stats{$cdr->{'Date'}}{$cdr->{'CarrierCode'}}{'NonConnects'} += $conn;
				$stats{$cdr->{'Date'}}{'TOTAL'}{'NonConnects'} += $conn;
				
				$stats{$cdr->{'DateUTC'}}{$cdr->{'CarrierCode'}}{'NonConnects'} += $conn;
				$stats{$cdr->{'DateUTC'}}{'TOTAL'}{'NonConnects'} += $conn;
			}

		}
		close(DATA);
	}

}

sub do_perc {
	my $val = shift;
	my $total = shift;

	$val = 0 unless defined $val;
	my $perc = '';
	if ((defined($total)) && ($total > 0)) {
		$perc = sprintf('%0.1f%%', 100 * $val / $total);
	}
	return "$val,$perc,";
}
sub print_csv_row {
	my $rowdt = shift;

	# Column: date
	$bigcsv .= "$rowdt,";
	
	print_cells("EST", $stats{$rowdt});
	print_cells("UTC", $statsUTC{$rowdt});
	
	$bigcsv .= "\n";
}

sub print_cells {
	my $tz = shift;
	my $dat = shift;
	
	for my $carr ('A', 'B') {
		if (defined($dat->{$carr})) {
			if (defined($dat->{$carr}{'Connects'})) {
				$bigcsv .= "," . $dat->{$carr}{'Connects'};
			} else {
				$bigcsv .= ",";
			}
			
			if (defined($dat->{$carr}{'Duration'})) {
				$bigcsv .= sprintf(",%d", $dat->{$carr}{'Duration'});
			} else {
				$bigcsv .= ",";
			}
			
			if (defined($dat->{$carr}{'NonConnects'})) {
				$bigcsv .= "," . $dat->{$carr}{'NonConnects'};
			} else {
				$bigcsv .= ",";
			}
			
		} else {
			$bigcsv .= ",,,";
		}
	} 
}

######################################################################

# === parse cdrs and populate %stats  and  %statsUTC
my $now = DateTime->now(time_zone => 'America/New_York'); 
my $nowstr = $now->ymd . ' ' . $now->hms;
my $dt  = DateTime->now(time_zone => 'America/New_York'); 
$dt->subtract_duration(DateTime::Duration->new(days => $days));
 
while (DateTime->compare($dt, $now) < 0) {
	cdr_read($dt->ymd(''));
	$dt = $dt->add(days => 1);
}


# === summarize
$csvhdr = "Produced: $nowstr\n,Date";
for my $tz ('Eastern', 'UTC') {
 	for my $carr ('A - GCNS', 'B - Selway') {
		for my $k ('Connects', 'Minutes', 'NonConnects') {
			$csvhdr .= ",\"$tz\n$carr\n$k\"";
		}
	} 
}
		
$dt  = DateTime->now(time_zone => 'America/New_York'); 
$dt->subtract_duration(DateTime::Duration->new(days => $days));
 
while (DateTime->compare($dt, $now) < 0) {
	print_csv_row($dt->strftime("%F"));
	$dt = $dt->add(days => 1);
}

open OUT, '>', "/dialer/website/cdr-summary/cdr-summary.csv" or die "opening failed: $!";
print OUT "$csvhdr\n"";
print OUT $bigcsv;
close OUT;