#!/usr/bin/perl

use strict;
use warnings;
use Text::CSV_XS;
use lib '/home/grant/H3/www/perl/';
use DialerUtils;
use IO::File;

my %outputs;
my %histo;

sub mine_file {
	my $filename = shift;
	my $PUfile;

	my $csv = Text::CSV_XS->new({ binary => 1 });
	if ($filename =~ /\.zip$/i) {
		if (! open($PUfile, "unzip -p '$filename'|")) {
			warn "Failed to open $filename: $!";
			return (0,0);
		}
	} else {
		if (! open $PUfile, '<', $filename) {
			warn "Failed to open $filename: $!";
			return (0,0);
		}
	}

	my $rcount = 0;
	my $fcount = 0;
	my $headers;

	while (my $row = $csv->getline($PUfile)) {

		if (! defined($headers)) {
			$headers = {};

			# determine which column heading to place map
			for (my $p = 0; $p < scalar(@$row); $p++) {
				my $c0 = $row->[$p];
				$c0 =~ s/[[:cntrl:]]//g; # remove newlines etc.
				if (length($c0) > 0) {
					$headers->{$c0} = $p;
				}
			}

			next; # we don't mine the headers
		}

		# mining over here
		$rcount++;
		my $state = $row->[$headers->{'STATE'}];
		my $val = $row->[$headers->{'PHONE'}];
		my $phone = DialerUtils::north_american_phnumber($val);

		next if ($phone eq '');

		if (! defined($outputs{$state})) {
			$outputs{$state} = new IO::File($state . ".txt", ">") or die "Failed to open for $state: $!";
		}
		
		$fcount++;
		$histo{$state}++;
		print {$outputs{$state}} "$phone\n";
		
	}

	close $PUfile;

	return ($rcount, $fcount);
}

my $rtot = 0;
my $ftot = 0;

my $inlist = `find /home/grant/leads/white-pages-2010/csv-clean -name '*.csv' | sort`;
while (length($inlist) > 0) {
	my $len = index($inlist, "\n");
	my $fname = substr($inlist, 0, $len);
	$inlist = substr($inlist, $len + 1);

	my ($r, $f) = mine_file($fname);
	print "$f mined out of $r rows in $fname\n";
	$rtot += $r;
	$ftot += $f;
}

for my $state (keys %outputs) {
	print "$state: " . $histo{$state} . "\n";
	undef $outputs{$state};
}

print "$ftot mined from $rtot rows in total\n";

