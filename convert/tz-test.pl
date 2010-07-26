#!/usr/bin/perl -I../www/perl

use warnings FATAL => 'all';
use strict;
use DialerUtils;

sub tztest {
	my @parms = splice(@_, 0, 6);
	my $expect = shift;

	my $got = DialerUtils::timezones_allowed(@parms);
	my $gotstr = '';
	for my $g (@$got) {
		$gotstr .= sprintf('%2d ', $g);
	}

	for my $p (@parms) { 
		if (defined($p)) {
			print "$p,"
		} else {
			print 'undef,'
		}
	}
	if ($gotstr ne $expect) {
		print "Failure: ";
		print "\nExpected:\n$expect\nGot     :\n$gotstr\n";
		exit;
	} else {
		print "... ok\n";
	}
}

sub expect {
	my $e = '';
	for my $z (sort { int($a) <=> int($b) } @_) {
		$e .= sprintf('%2d ', $z);
	}
	return $e;
}

tztest(12,30,11,35,12,29,expect());
tztest(12,30,11,35,11,35,expect());
tztest(12,30,11,35,12,30,expect());
tztest(12,30,11,35,2,29,expect());

tztest(0,0,24,0,undef,undef,expect(0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23));

tztest(0,0,24,0,9,0,expect(0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23));
tztest(9,0,21,0,0,30,expect(4,5,6,7,8,9,10,11,12,13,14,15));
tztest(9,0,21,0,1,30,expect(5,6,7,8,9,10,11,12,13,14,15,16));
tztest(9,0,21,0,8,30,expect(12,13,14,15,16,17,18,19,20,21,22,23));
tztest(9,0,21,0,9,30,expect(13,14,15,16,17,18,19,20,21,22,23,0));
tztest(9,0,21,0,10,30,expect(14,15,16,17,18,19,20,21,22,23,0,1));
tztest(9,0,21,0,11,30,expect(15,16,17,18,19,20,21,22,23,0,1,2));
tztest(9,0,21,0,12,30,expect(16,17,18,19,20,21,22,23,0,1,2,3));
tztest(9,0,21,0,13,30,expect(17,18,19,20,21,22,23,0,1,2,3,4));
tztest(9,0,21,0,14,30,expect(18,19,20,21,22,23,0,1,2,3,4,5));
tztest(9,0,21,0,20,50,expect(0,1,2,3,4,5,6,7,8,9,10,11));

tztest(12,0,13,0,11,59,expect(23));
tztest(12,0,13,0,12,01,expect(0));
tztest(12,0,13,0,13,01,expect(1));
tztest(12,0,13,0,14,01,expect(2));
tztest(12,0,13,0,15,01,expect(3));

tztest(12,30,12,35,12,29,expect());
tztest(12,30,12,35,12,31,expect(0));
tztest(12,30,12,35,12,36,expect());

