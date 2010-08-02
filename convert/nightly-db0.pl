#!/usr/bin/perl

# does what needs to be done at change of day

use strict;
use warnings;

use lib '/home/grant/H3/www/perl';
use DialerUtils;
use Logger;

my $log = Logger->new('/var/log/nightly.log');

$log->debug("connecting to the database");
my $sbn2 = DialerUtils::sbn2_connect(); # connect to the database

sub load_nonconnects {
	my $ncf = shift;
	my $interval = shift;

	if (! -f "/root/$ncf") {
		$log->warn("$ncf was not found, skipping");
		return
	}

	my $tname = "/var/lib/mysql/sbn2/nonconn.txt";
	system("install --group=mysql --owner=mysql --mode=0644 -T /root/$ncf $tname");

	$log->debug("loading data from $ncf starts");
	$sbn2->do("load data infile 'nonconn.txt' ignore into table dncnonconn (DN_PhoneNumber) 
		set DN_Expires = date_add(now(), interval $interval day)");
	unlink($tname);
	$log->debug("loading data from $ncf finishes");
}

# --------------------------


# dncnonconn
load_nonconnects('BadNumber.txt', 21);
load_nonconnects('NonConnectedNumber.txt', 7);

system('rm -f /var/lib/mysql/in-out/*');

$log->info("deleting expired dncnonconn rows");
$sbn2->do("delete quick from dncnonconn where DN_Expires < now() or exists (select 'x' from phones where PH_Number = DN_PhoneNumber)");

$log->info("optimizing dncnonconn");
$sbn2->do("optimize table dncnonconn");

$log->debug("disconnecting from the database");
$sbn2->disconnect;
$log->fin;
