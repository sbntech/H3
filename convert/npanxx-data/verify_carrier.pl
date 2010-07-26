#!/usr/bin/perl

=pod
reads in stripped cdrs
<PhoneNumber>,<rounded duration>,<carrier charge>

looks up the rate and compares
=cut

use strict;
use warnings FATAL => 'all';
use Text::CSV_XS;
use lib '/dialer/convert/npanxx-data';
use Rates;
use lib '/home/grant/sbn-git/www/perl';
use DialerUtils;
my $sbn2 = DialerUtils::sbn2_connect();

my $r = initialize Rates(1);
my $carrier = 'B';
my $filename = 'carrier-cdrs.csv';
open RESF, '>', '/home/grant/carrier-verify.csv' or die;

my $PUfile;
my $csv = Text::CSV_XS->new({ binary => 1 });
open $PUfile, '<', $filename || die "Failed to open $filename: $!";
print RESF "Phone,State,Secs,CarrierCharge,CarrierRate,OurRate,RateDiff,OurCharge,BestRoute,AltRoute,ScrubType\n";

my $lcount = 0;
my $ctotal = 0.0;
my $ototal = 0.0;

while (my $row = $csv->getline($PUfile)) {
	my ($number,$duration,$charge) = @$row;
	$lcount ++;

	my $nn = $r->lookup_number($number, 1, 1, $sbn2);
	my $state = $nn->{'StateCode'};

	my $cr = 0.0;
	my $carrate = (60 * $charge) / $duration;
	my $ocharge = 0.0;
	my $diff = 999.99;

	if (defined($nn->{'Rates'}{$carrier})) {
		$cr = $nn->{'Rates'}{$carrier};

		$diff = sprintf('%0.7f',$carrate - $cr);
		$ocharge = ($duration * $cr) / 60;
	}

	$ctotal += $charge;
	$ototal += $ocharge;

	my $st = $nn->{'ScrubType'};
	$st = 'UNDEFINED' unless defined($st);

	print RESF "$number,$state,$duration,$charge,$carrate,$cr,$diff,$ocharge," .
					$nn->{'BestCarriers'} . "," . $nn->{'AltCarriers'} . 
					",$st\n";
}

print "$lcount cdrs checked.\n";
printf "Carrier total charge: %0.2f\n", $ctotal;
printf "Our total charge: %0.2f\n", $ototal;
	
$sbn2->disconnect;
close $PUfile;
close RESF;
