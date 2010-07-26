#!/usr/bin/perl

use strict;
use warnings FATAL => 'all';

my %npanxxb;

my $cdrs = 0;
my $records = 0;
my $totdur = 0;
my $fcount = 0;

open OUTPUT, '>', 'sbn-sample.txt' or die "failed to open: $!"; # in case it dies do it first

foreach my $file (`find /dialer/projects -wholename "/dialer/projects/*/cdr/cdr-2009-04-2*"`) {
	chomp $file;

	$fcount++;

	if ($file =~ /.*\.zip/) {
		if (! open(DATA, "unzip -p '$file'|")) {
			die "Failed to open $file: $!";
		}
	} else {
		open(DATA, '<', $file) || die "Failed to open $file: $!";
	}
	print "reading file $file ... ";

	while(my $line=<DATA>)
	{
		my $cdr = DialerUtils::sbncdr_parser($line);
		die "unparsable cdr $line" unless defined ($cdr);
		
		$cdrs++;

		if ($cdr->{'Duration'} > 0) {
			$totdur += $cdr->{'Duration'};
			$npanxxb{substr($cdr->{'CalledNumber'},0,7)} += $cdr->{'Duration'};
		}

	}
	close(DATA);

	print "$cdrs cdrs read so far, from $fcount files\n";
}

for my $k (sort keys %npanxxb) {
	$records++;
	print OUTPUT "$k," . $npanxxb{$k} . "\n";
}

close OUTPUT;

print "$records records written, with total duration = " . int($totdur/60) . " minutes. (from $cdrs cdrs in $fcount files)\n";

