#!/usr/bin/perl

use strict;
use warnings FATAL => 'all';
use lib '/home/grant/sbn-git/www/perl';
use DialerUtils;

=pod

Run from cron

It created new queues.conf and agents.conf for asterisk.

Also, this program determines if the new creations are any different from the old ones
and reloads them if needed.

=cut


my $QUEUE_HEADER=
"[general]
persistentmembers = no
autofill = yes
autopause=no
";

my $QUEUE_BOILER_PLATE=
"strategy = leastrecent
timeout = 5
leavewhenempty = strict
joinempty = loose
eventwhencalled = yes
";

my $AGENT_HEADER=
"[general]
persistentagents = no

[agents]
endcall = yes
enddtmf = *
ackcall = no
";

my $dbh = DialerUtils::db_connect();

my $TEMP = '/tmp/queues.conf';
open QFILE, '>', $TEMP or die "failed to open $TEMP: $!";
print QFILE "$QUEUE_HEADER\n";

my $AGTEMP = '/tmp/agents.conf';
open AFILE, '>', $AGTEMP or die "failed to open $AGTEMP: $!";
print AFILE "$AGENT_HEADER\n\n";

my $pref = $dbh->selectall_arrayref("select PJ_Number from project 
			where PJ_Type = 'C'", { Slice => {}});

for my $pjrow (@$pref) {

	my $pjnum = $pjrow->{'PJ_Number'};

	print QFILE "\n[pjq$pjnum]\n";
	print QFILE $QUEUE_BOILER_PLATE;

	my $aref = $dbh->selectall_arrayref("select * from agent 
			where AG_Project = $pjnum", { Slice => {}});

	for my $agrow (@$aref) {
		my $anum = $agrow->{'AG_Number'};
		print QFILE "member => Agent/$anum\n";

		my $pw = uc($agrow->{'AG_Password'});
		# convert to phone keypad values
		$pw =~ tr/ABCDEFGHIJKLMNOPQRSTUVWXYZ/22233344455566677778889999/;
		$pw =~ tr/0-9/1/c; # replace all non-digits with a 1

		print AFILE "agent => $anum,$pw," . $agrow->{'AG_Name'} . "\n";
	}
}

close QFILE;
close AFILE;

# check if $TEMP is different to /etc/asterisk/queues.conf
my $diff = `diff -q -N /etc/asterisk/queues.conf $TEMP`;
if ($diff and length($diff) > 0) { 
	system("mv $TEMP /etc/asterisk/");
	system("asterisk -r -x 'module reload app_queue'");
}

# check if $AGTEMP is different to /etc/asterisk/agents.conf
$diff = `diff -q -N /etc/asterisk/agents.conf $AGTEMP`;
if ($diff and length($diff) > 0) { 
	system("mv $AGTEMP /etc/asterisk/");
	system("asterisk -r -x 'module reload chan_agent.so'");
}
