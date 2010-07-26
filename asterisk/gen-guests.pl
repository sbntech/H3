#!/usr/bin/perl

use strict;
use warnings;
use lib '/home/grant/sbn-git/www/perl';
use DialerUtils;

my $dbh = DialerUtils::db_connect(); # connect to the database
my $curCust = 0;

open GSIP, '>', '/home/grant/sbn-git/asterisk/carrier-config/guests-sip.conf'
	or die "failed to open guest file: $!";

my $res = $dbh->selectall_arrayref("select * 
	from agent, project, customer
	where AG_Project = PJ_Number and
	AG_Customer = CO_Number and PJ_CustNumber = CO_Number and
	PJ_Type = 'C'
	order by AG_Customer", { Slice => {}});

if (!defined($res)) {
	print "-- no agents\n";
	exit;
}

for my $row (@$res) {

	if ($curCust != $row->{'CO_Number'}) {
		# print customer header
		printf "Customer: %s (Id=%d)\n", $row->{'CO_Name'}, $row->{'CO_Number'};
		$curCust = $row->{'CO_Number'};
	}

	my $id = 'agent' . $row->{'AG_Number'};
	my $pw = $row->{'AG_Password'};
	my $ext = sprintf('%04d', $row->{'AG_Number'});

	printf("  %-15s: username=%s password=%s sipAddress=sip:8$ext\@216.66.234.212:8060\n",
		$row->{'AG_Name'}, $id, $pw);

	print GSIP <<EndAgent
[$id]
type=friend 			
secret=$pw
qualify=yes 
host=dynamic
insecure=port,invite
context=subscribers
callerid=$id <999888$ext>
nat=yes
canreinvite=no
dtmfmode=auto
call-limit=1

EndAgent
;
}
    
$dbh->disconnect;
close GSIP;
