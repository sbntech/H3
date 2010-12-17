#!/usr/bin/perl

use strict;
use warnings;
use lib '/home/grant/H3/www/perl';
use DialerUtils;

my $dbh = DialerUtils::db_connect(); # connect to the database
my $curCust = 0;
my $curSpyGroup = 0;

sub derive_SPYGROUP {
	my $cust = shift;

	my $curSpyGroup = 103 + ($cust % 53) * $cust;
}


open GSIP, '>', '/home/grant/H3/asterisk/carrier-config/guests-sip.conf'
	or die "failed to open guest file: $!";

open GEXT, '>', '/home/grant/H3/asterisk/carrier-config/guests-plan.conf'
	or die "failed to open guest ext file: $!";

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
		$curSpyGroup = derive_SPYGROUP($curCust);

		print GEXT <<EndSpyExt
exten => $curSpyGroup,1,ChanSpy(SIP,qwg($curSpyGroup))

EndSpyExt
;

		print GSIP <<EndSpy
[spy$curCust]
type=friend 			
secret=$curSpyGroup
qualify=yes 
host=dynamic
insecure=port,invite
context=starthere
nat=yes
canreinvite=no
dtmfmode=auto
call-limit=1

EndSpy
;
	}

	my $id = 'agent' . $row->{'AG_Number'};
	my $pw = $row->{'AG_Password'};
	my $ext = sprintf('%04d', $row->{'AG_Number'});

	printf("  %-15s: username=%s password=%s sipAddress=sip:8$ext\@67.209.46.100:8060\n",
		$row->{'AG_Name'}, $id, $pw);

	print GEXT <<EndAgentExt
exten => 8$ext,1,log(NOTICE,Agent extension 8$ext called)
exten => 8$ext,n,Set(SPYGROUP=$curSpyGroup)
exten => 8$ext,n,dial(sip/$id)

EndAgentExt
;

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
close GEXT;

#print "\nexecuting sip reload:\n";
#print `asterisk -x 'sip reload'`;
