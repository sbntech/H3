#!/usr/bin/perl

use strict;
use warnings FATAL => 'all';

use lib '/home/grant/sbn-git/www/perl';
use DialerUtils;
use DBI;
use lib '/home/grant/sbn-git/convert/npanxx-data';
use Rates;
$|=1;

my $dbh = DialerUtils::db_connect(); # connect to the database
my $sbn2 = DialerUtils::sbn2_connect(); # connect to the database
my $r = initialize Rates(1);

my $pjnum = 1;
while (1) {
	print "Enter project number [$pjnum]: ";
	my $inp = <STDIN>;
	$inp =~ tr/0-9//cd;
	if (length($inp) > 0) {
		$pjnum = int($inp);
	}

	my $number;
	do {
		print "Enter phone number: ";
		$number = <STDIN>;
		$number =~ tr/0-9//cd;
	} until ($number =~ /\d{10}/);

	print "pjnum=$pjnum, number=$number\n";

	my $ph = $sbn2->selectrow_hashref("select * from phones where PH_Number = $number limit 1");
	print "Phones:";
	if (defined($ph->{'PH_Number'})) {
		print " A=";
		if (defined($ph->{'PH_CarrierA'})) {
			print $ph->{'PH_CarrierA'};
		} else {
			print "null";
		}
		print " F=";
		if (defined($ph->{'PH_CarrierF'})) {
			print $ph->{'PH_CarrierF'};
		} else {
			print "null";
		}
		print "\n";
	} else {
		print " no row for $number\n";
	}

	my $ci = $dbh->selectrow_hashref("select PJ_CustNumber, CO_ResNumber, PJ_Description, CO_Name from project, customer 
		where PJ_CustNumber = CO_Number and PJ_Number = $pjnum limit 1");

	if (! defined($ci->{'PJ_CustNumber'})) {
		print "Failed to read row for project $pjnum\n";
		next;
	}

	my $nn = $r->lookup_number($number, 
			$ci->{'PJ_CustNumber'}, $ci->{'CO_ResNumber'}, $sbn2);
	
	if (defined($nn)) {
		print "Rates:\n";
		for my $k (sort keys %$nn) {
			if ($k eq 'Rates') {
				for my $r (keys %{$nn->{$k}}) {
					print "Carrier $r=" . $nn->{$k}{$r} . "\n";
				}
			} else {
				my $val = $nn->{$k};
				$val = "UNDEFINED" unless defined($val);
				print "$k=$val\n";
			}
		}
		print "\n";
	}

	print "\n\n";

}

$dbh->disconnect;
$sbn2->disconnect;


