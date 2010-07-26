#!/usr/bin/perl

use strict;
use warnings;

die "needs to be rewritten to use the new npanxx table";

# PREP: 
	# npa-nxx-companytype-ocn.csv from http://www.telcodata.us/telcodata/download?file=npa-nxx-companytype-ocn.csv
	# export rate worksheets (Qwest Domestic Outbound Rates APN.xls) as csv files, edit them to remove headers and such
	# check default rates $intra and $inter
	
my $margin = 0.14;
my $intra = 0.0349;
my $inter = 0.0175;

my %nnlo;
my %locn;

# read the LATA/OCN --> NPANXX mapping
print "Loading npanxx --> LATA/OCN mapping\n";
my $count = 0;
open(LATAOCN, '<', 'npa-nxx-companytype-ocn.csv') or die "Cannot open LATA/OCN file: $!";
while (<LATAOCN>) {
	# note: lata is not "quoted"
	if (/^(\d{3}),(\d{3}),"([^"])*","?([^",]*)"?,"([^"]*)",([^"]*),"([^"]*)","([^"]*)".*/) {
		#  1:npa    2:nxx  3:type      4:ocn      5:company 6:lata  7:ratectr  8:state
		$nnlo{"$1$2"} = {'lata' => $6, 'ocn' => $4, 'state' => $8};
		$count++;
	} else {
		print "$_ not matched\n";
	}
}
close(LATAOCN);
print "$count npanxx rows\n";

# read the rates
sub loadrates {
	my $filename = shift;
	my $key = shift;

	open(RF, '<', $filename) or die "$filename failed to open: $!";
	while (<RF>) {
		if (/^(\d*),"?([^",]*)"?,.*\$([\.0-9]*).*/) {
			my ($lata, $ocn, $rate) = ($1,$2,$3);
			if ($rate > 0.3) {
				print "$filename: $lata-$ocn has rate=$rate !!!\n";
			} else {
				my $k = "$lata-$ocn-$key";
				if (defined($locn{$k})) {
					print "$filename:  $lata-$ocn has mutiple rates for $key\n";
				} else {
					$locn{$k} = $rate;
				}
			}
		} else {
			print "$filename: $_ not matched\n";
		}
	}
	close(RF);
}

print "Loading the rates\n";
loadrates('QWEST-Interstate.csv', 'inter');
loadrates('QWEST-Intrastate.csv', 'intra');


# check for missing rates: i.e. will use default in these cases
print "Checking for missing/default rates\n";
open(MISS, '>', 'LATA-OCN-without-rates.txt') or die;
for my $n (keys %nnlo) {
	my $lo = $nnlo{$n}->{'lata'} . '-' .  $nnlo{$n}->{'ocn'};
	my $msg = "";

	$msg = 'inter ' unless defined($locn{"$lo-inter"});
	$msg .= 'intra ' unless defined($locn{"$lo-intra"});

	print MISS "$n with LATA-OCN=$lo $msg\n" unless $msg eq "";
}
close(MISS);


# rating starts here ----v
my $infile = 'CS171455.csv';
$infile = 'CS175221.csv'; # March 05 - 2008
$infile = 'CS235617.csv'; # April 02 - 2008
$infile = 'CS143507.csv'; # April 17 - 2008 (for April 2-16)
print "Rating $infile\n";

my %counts;
my $totaldur = 0;
my $totcost = 0;
open(INF, '<', $infile) or die;
open(OUTF, '>', "rated-$infile") or die;

print "Skipping first line: HEADER\n";
<INF>;

while (<INF>) {
	if (/^([^,]*,[^,]*),(\d*),[^,]*,([^,]*),([^,]*),(.*)$/) {		
		my ($dt, $duration, $orig, $term) = ($1,$2,$3,$4);
		$counts{'Total CDRs'}++;
		if ($duration > 0) {
			$counts{'Connected CDRs'}++;

			my $oline = "$dt,$duration,$orig,$term,"; # line to be printed
			my $owarn = ""; # any warnings printed

			$totaldur += $duration;
			my $rkind = 'intra'; # rate kind
			my $orig_nn;
			my $term_nn;

			if ($orig =~ s/^\s*1?(\d{10})\s*$/$1/) {
				$orig_nn = substr($orig,0,6);
				if (! defined($nnlo{$orig_nn})) {
					$owarn .= "Cannot find origin npanxx. ";
					$counts{'Missing origin npanxx'}++;
				} 
			} else {
				$counts{'Unusable origination'}++;
				$orig_nn = 'unknown';
				$owarn .= "Unusable origin. ";
			}

			if ($term =~ s/^\s*1?(\d{10})\s*$/$1/) {
				$term_nn = substr($term,0,6);

				if (!defined($nnlo{$term_nn})) {
					$counts{'Missing termination npanxx'}++;
					$owarn .= "Cannot find info for termination npanxx. ";
					$oline .= "0.00,Error";
				} else {
					if (defined($nnlo{$orig_nn})) {
						if ($nnlo{$orig_nn}->{'state'} ne $nnlo{$term_nn}->{'state'}) {
							$rkind = 'inter';
						}
					} else {
						# bad origin ==> INTER except calls to New York which are INTRA 
						if ($nnlo{$term_nn}->{'state'} ne 'NY') {
							$rkind = 'inter';
						}
					}

					my $k = $nnlo{$term_nn}->{'lata'} . '-' . 
						$nnlo{$term_nn}->{'ocn'} . "-$rkind";

					my $rate = ($rkind eq 'inter') ? $inter : $intra;

					if (!defined($locn{$k})) {
						$owarn .= "Using default $rkind-state rate for termination npanxx. ";
						$counts{"Default $rkind-state rate used"}++;
					} else {
						$rate = $locn{$k};
					}

					my $cost = (($duration / 60) * $rate) * (1 + $margin);
					$oline .= "$cost,$rkind";
					$totcost += $cost;
				}

			} else {
				$oline .= "0.00,Error";
				$counts{'Unusable termination'}++;
				$owarn .= "Unusable termination. ";
			}

			print OUTF "$oline,$owarn\n";
		}
	} else {
		$counts{"Unparsable CDRs"}++;
		print "$_ not matched\n";
	}
}
close(INF);
close(OUTF);

for my $m (keys %counts) {
	printf("%-30s: %d\n", $m, $counts{$m});
}
printf("%-30s: ", "Total duration");
print "$totaldur (" . ($totaldur / 60) . " minutes)\n";
printf("%-30s: ", "Total cost");
print "$totcost\n";
