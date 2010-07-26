#!/usr/bin/perl

use strict;
use warnings;

use lib '/dialer/www/perl';
use DialerUtils;
use Time::HiRes qw( gettimeofday tv_interval );

# this parameter is here for testing purposes only
my $interval = $ARGV[0];
$interval = 'interval 64 minute' unless defined($interval);

my $t0 = [gettimeofday()];

sub flog {
	my $msg = shift;

	my ($dt, $tm) = DialerUtils::local_datetime();

	my $t1 = [gettimeofday()];
	my $elapsed = tv_interval($t0, $t1);
	my $m = sprintf('%0.3f', $elapsed);
	$t0  = $t1;

	print "$dt $tm ($m): $msg\n";
}

flog("starts");
my $dbh = DialerUtils::db_connect(); # connect to the database

sub permanent_board_block {

	my $sw = shift;
	my $t1 = shift;

	my $c = $dbh->do(
		"update line set ln_status = 'B', ln_action = '888888',
		ln_lastused = now(), ln_reson = 'permanent block' where
		ln_status != 'E' and ln_status != 'B' and
		ln_switch = '$sw' and ln_board = '$t1'");

	flog("permanent block of $sw-$t1");

}

$dbh->do("update switch set SW_callsuur = 0");
flog("updated switches");

my $nfref = $dbh->selectall_arrayref("select RE_Project from report where RE_Date = current_date() and RE_Agent = 9999 and RE_Calls > 10",
	{ Slice => {}});
flog("selected projects that ran today");

for my $tblrow (@$nfref) {
	my $tbl = 'projectnumbers_' . $tblrow->{'RE_Project'};

	# numbers lost that were sent for redial are marked for deletion 
	# numbers lost (NOT for redialing) are re-readied

	my $cnt = $dbh->do("update $tbl
		set PN_Sent_Time = null, PN_Status = 'R'
		where PN_Sent_Time < date_sub(now(), $interval) 
			and PN_Status = 'C'");

	flog("$tbl updated $cnt rows");
}

# takes numbers but never connects - could automatically block
permanent_board_block('D105', 1); 
permanent_board_block('D105', 13); 
permanent_board_block('D105', 14); 
permanent_board_block('D106', 1); 
permanent_board_block('D106', 2); 
permanent_board_block('D114', 14); 
permanent_board_block('D122', 12); 
permanent_board_block('D155', 2); 
permanent_board_block('D155', 3); 
permanent_board_block('D155', 6); 
permanent_board_block('D159', 11); 


$dbh->disconnect;
flog("ends");
