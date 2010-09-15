#!/usr/bin/perl

my %CARRLOOKUP = ( A =>  'Selway', 'B' => 'GCNS', 'X' => 'Trial');

use strict;
use warnings FATAL => 'all';
use lib '/dialer/convert/npanxx-data';
use Rates;
use lib '/home/grant/H3/www/perl';
use DialerUtils;

my $r = initialize Rates(1);
my $TrialDefault = 0.04; # leave undef or 0.0 if there is none
$r->load_rate_file('/ZM/people/grant/H3-private/rate-decks/trial-x.csv', 'Trial', 'X');

# *** analyse ***
print "Analysing the rates\n";
my %sample;
my %types;

my %cheap;
my %good;
my %okay;
my %steep;
my %expensive;
my %noroutes;
my %XR; # no route prefixes
my %plans;

my $nrcount = 0;
my $nrdur = 0;

open SAMPLE, '<', 'sbn-sample.txt' || die "failed to open sample data: $!";

while (my $l = <SAMPLE>) {
	my $npa = substr($l,0,3);
	my $nxx = substr($l,3,3);
	my $nn4 = substr($l,0,4);
	my $nn5 = substr($l,0,5);
	my $block = substr($l,6,1);
	my $seconds = 12;

	my $number = "$npa$nxx$block" . '000';
	my $nn = $r->lookup_number($number, 1, 1);

	$nn->{'Rates'}{'X'} = $r->{'Trial'}{"$npa$nxx"};
	# Trial (X) ---
	TRYPREFIX: for my $prefix ( "$npa$nxx$block", "$npa$nxx", $nn5, $nn4, $npa ) {
		if (defined($r->{'Trial'}{$prefix})) {
			$nn->{'Rates'}{'X'} = $r->{'Trial'}{$prefix};
			$nn->{'Routable'} = 1;
			last TRYPREFIX;
		}
	}
	if ((!defined($nn->{'Rates'}{'X'})) && (defined($TrialDefault)) && ($TrialDefault > 0)) {
			$nn->{'Rates'}{'X'} = $TrialDefault;
			$nn->{'Routable'} = 1;
	}

	if ($nn->{'Routable'} == 0) {
		#print "$l is not routable!\n";
		$nrcount++;
		$nrdur += $seconds;
	}

	$plans{$nn->{'BestCarriers'}} += $seconds;

	$sample{'TotalSeconds'} += $seconds;
	$sample{'TotalCount'}++;

	for my $c (sort keys %CARRLOOKUP) {
		if (defined($nn->{'Rates'}{$c})) {
			my $cr = $nn->{'Rates'}{$c};
			if ($cr > 0.03) {
				$expensive{$c} += $seconds;
			} elsif ($cr > 0.012) {
				$steep{$c} += $seconds;
			} elsif ($cr > 0.01) {
				$okay{$c} += $seconds;
			} elsif ($cr > 0.007) {
				$good{$c} += $seconds;
			} else {
				$cheap{$c} += $seconds;
			}
		} else {
			$noroutes{$c} += $seconds;
			if ($c eq 'X') {
				$XR{"$npa$nxx"}++;
			}
		}
	}

	$types{$nn->{'Type'}}++;
}

print "Sample had " . $sample{'TotalCount'} . " records\n";
print "Sample had " . $sample{'TotalSeconds'} . " total seconds\n";
print "Sample has $nrcount non-routable records with $nrdur duration total.\n";

print "OCN Type histogram :\n";
for my $t (sort keys %types) {
	printf "%-12s :%0.2f%%\n", $t, (100 * $types{$t}) / $sample{'TotalCount'} ;
}

# headings
printf '%12s  ', 'Price';
for my $c (sort keys %CARRLOOKUP) {
	printf "%10s", "$c:" . $CARRLOOKUP{$c};
}
print "\n";
	
# rows
stat_row('Cheap <.7c', \%cheap);
stat_row('Good .7-1c', \%good);
stat_row('Okay .1-1.2c', \%okay);
stat_row('Steep 1.2-3c', \%steep);
stat_row('Expensive', \%expensive);
stat_row('No route', \%noroutes);
print "\n";

sub stat_row {
	my $label = shift;
	my $data = shift;

	printf '%12s  ', $label;

	for my $c (sort keys %CARRLOOKUP) {
		my $v = '          ';
		if (defined($data->{$c})) {
			my $perc = sprintf '%3.1f%%', 100 * $data->{$c} / $sample{'TotalSeconds'};
			$v = substr('                 ',0, 10 - length($perc)) . $perc;
		}
		print $v;
	}
	print "\n";
}
	
# print plans
printf "\n%12s %7s\n", 'Plan', 'Perc';

for my $p (sort keys %plans) {
	printf "%12s %3.1f\n", $p, 100 * ($plans{$p} / $sample{'TotalSeconds'});
}

open NOROUTES, '>', '/home/grant/no-routes.prefixes.csv' or die;
print NOROUTES "Prefix,Count\n";
map { print NOROUTES "$_," . $XR{$_} . "\n" } keys %XR;
close NOROUTES;
