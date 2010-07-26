#!/usr/bin/perl

# used for the conversion to new caller id tables: custcallerid and rescallerid

use strict;
use warnings;

use lib '/home/grant/sbn-git/convert';
use lib '/home/grant/sbn-git/www/perl';
use DialerUtils;

my %cust_sets;
my %res_sets;

my $dbh = DialerUtils::db_connect(); # connect to the database
open(RES, '>', 'rescallerid.txt') || die "failed to open:$!";
open(CUST, '>', 'custcallerid.txt') || die "failed to open:$!";

my $c = $dbh->selectall_arrayref("select CO_ResNumber, CO_Number, CO_Callerid, CO_Name from customer",
	{ Slice => {} });

for my $cust (@$c) {
	print $cust->{'CO_Number'} . ': ' . $cust->{'CO_Name'} . ' ==>';
	my $cnt = 0;
	if ((defined($cust->{'CO_Callerid'})) && (length($cust->{'CO_Callerid'}) > 9)) {
		for my $cid (split(/\n/, $cust->{'CO_Callerid'})) {
			$cust_sets{$cust->{'CO_Number'}}{$cid} = 1;
			$res_sets{$cust->{'CO_ResNumber'}}{$cid} = 1;
			$cnt++;
		}
	}
	print " $cnt, projects: ";
	my $p = $dbh->selectall_arrayref("select distinct PJ_OrigPhoneNr 
		from project where PJ_CustNumber = " . $cust->{'CO_Number'} . 
		" and length(PJ_OrigPhoneNr) = 10", { Slice => {} });

	for my $pj (@$p) {
		print '.';
		my $cid = $pj->{'PJ_OrigPhoneNr'};
		$cust_sets{$cust->{'CO_Number'}}{$cid} = 1;
		$res_sets{$cust->{'CO_ResNumber'}}{$cid} = 1;
	}
	print "\n";
}

$dbh->disconnect;

for my $cust (sort keys %cust_sets) {
	for my $cid (sort keys %{$cust_sets{$cust}}) {
		print CUST "$cust\t$cid\t2000-01-01 00:00:00\n";
	}
}
close CUST;

for my $res (sort keys %res_sets) {
	for my $cid (sort keys %{$res_sets{$res}}) {
		print RES "$res\t$cid\tN\t2000-01-01 00:00:00\n";
	}
}
close RES;

