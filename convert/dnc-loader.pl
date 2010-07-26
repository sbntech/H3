#!/usr/bin/perl

use strict;
use warnings FATAL => 'all';
$|=1;

my $filename = $ARGV[0];

my $cdbdir = '/home/grant/maindnc';
die "cdb dir not found" unless -d $cdbdir;

use Time::HiRes qw( gettimeofday tv_interval );

my $e;
my $t0 = [gettimeofday()];
my %files;

my $count = 0;
open DNCFILE, '-|', "/usr/bin/7z x -so $filename" or die "Failed to read DNC file: $!";

while (<DNCFILE>) {
	my $num = $_;
	$num =~ tr/0-9//cd;

	my $pre = substr($num,0,2);
	my $rest = substr($num,2);
	if (! defined($files{$pre})) {
		open $files{$pre}, ">> $cdbdir/$pre.in" 
			or die "Failed to open for $pre: $!";
	}

	print { $files{$pre} } "+8,0:$rest->\n";
	$count++;
	if (($count % (10**7)) == 0) {
		$e = tv_interval($t0, [gettimeofday()]);
		print "$count dnc numbers prep'ed so far ($e seconds elapsed)\n";
	}
}

for my $ac (keys %files) {
	print { $files{$ac} } "\n"; # end-of-data
	close $files{$ac};

	print "Making $ac.cdb\n";
	system("cdbmake $cdbdir/$ac.cdb $cdbdir/work.$ac < $cdbdir/$ac.in"); 
	unlink("$cdbdir/$ac.in");
}

$e = tv_interval($t0, [gettimeofday()]);
print "\n$count dnc numbers, took $e seconds\n";
