#!/usr/bin/perl

use strict;
use warnings;
use lib '/home/grant/sbn-git/convert';
use lib '/home/grant/sbn-git/www/perl';
use DialerUtils;
use AstManager;
use DateTime;
use Logger;
use Time::HiRes qw( gettimeofday tv_interval usleep );

die "FATAL: projects voice prompts missing" unless (-d '/var/lib/asterisk/sounds/projects/_1');
die "FATAL: standard prompts missing" unless (-d '/var/lib/asterisk/sounds/sbn/StandardPrompts');

my $dialerId = 'WHAM';
# dynamic parameters (from switch table via SW_VoipCPS)
my $o_gap = 6000; # gap in seconds between originations
my $cps = 0;

my $outchan = 'sip/bbcom-ivan/2610';
my $log = Logger->new('/var/log/astdialer.log');

# attempt to start asterisk (no harm if it is already started)
system('/usr/sbin/asterisk');
sleep(1);

my $ast = new AstManager('sbnmgr', 'iuytfghd', 'localhost', 'on', $log);
$ast->check_limits();

my $db0 = DialerUtils::db_host(); 
my $dbh = DialerUtils::db_connect($db0);
my $o_time = [ gettimeofday() ]; # used to restrict the pace of originations
my $o_total = 0;
my $ITERGAP = 60;
my $nextIter = time() - 1;

sub init_dialer {

	# update table switch
	my $db = $dbh->selectrow_hashref("select SW_Number, SW_VoipCPS, SW_VoipPorts from switch where SW_ID = '$dialerId'");
	if ($db->{SW_Number}) {
		$dbh->do("update switch set SW_IP = 'ASTERISK', 
			SW_Status = 'A', SW_lstmsg = current_timestamp(), SW_Start = current_timestamp(),
			SW_callsuur = 0, SW_databaseSRV = 'Blaster' where SW_ID ='$dialerId' and SW_Number = " . $db->{SW_Number} );
	} else {
		$dbh->do("insert into switch
			(SW_IP, SW_Status, SW_ID, SW_lstmsg, SW_start, SW_callsday, SW_callsuur, SW_databaseSRV, SW_VoipCPS, SW_VoipPorts) values
			('ASTERISK', 'A', '$dialerId', current_timestamp(), current_timestamp(), 0, 0, 'Blaster', 0, 0)");
	}

	reread_config();
}

sub summarize {

	my $acps = $o_total / $ITERGAP;
	$log->info("SUMMARY: dials done=$o_total, o_gap=$o_gap, target cps=$cps, actual cps=$acps");
	$o_total = 0;

}


sub reread_config {

	my $sw = $dbh->selectrow_hashref("select SW_VoipCPS from switch where SW_ID = '$dialerId'");

	# Calls Per Second
	$cps = $sw->{'SW_VoipCPS'};
	if ((defined($cps)) && ($cps > 0)) {
		$o_gap = 1 / $cps;
	} else {
		$o_gap = 600;
		$cps = 0;
	}

}

sub originate {
	return unless $ast->{'running'} == 3;

	my $now = [gettimeofday()];
	my $elapsed = tv_interval($o_time, $now);
	return if ($elapsed < $o_gap);

	my $number = 5555551000 + int(rand(8000));

	my $aid = $ast->originate_action_id();
	my $chan = "$outchan$number";

	$ast->send_action("Originate", {
			'Channel'	=> $chan,
			'Exten'		=> 's',
			'Variable'	=> [], # array ref
			'Priority'	=> 'Machine',
			'Context'	=> 'pjtypeCL',
			'CallerID'	=> '8663473473',
			'Timeout'	=> 30 * 1000, # how long to let it ring for 20k = 4 rings, 30k=5.5rings
			'Async'		=> 1
			}, { }, $aid);

	$o_total++;
	$o_time = $now; # used to restrict the pace of originations

}

sub exit_handler {
	$log->info("signal caught: STOPPING");
	$ast->{'running'} = 0;
	$nextIter = time() - 10;
}

# +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++ main

$SIG{INT} = \&exit_handler;
$SIG{QUIT} = \&exit_handler;
$SIG{TERM} = \&exit_handler;

init_dialer();

while ($ast->{'running'} > 0) {
	my $nowt = time();


	if ($nextIter < $nowt) {

		summarize();
		reread_config();

		$nextIter = $nowt + $ITERGAP;
	}

	originate();

	if ($ast->{'running'} > 0) {
		$ast->handle_events(\&originate,
			{ 
			});
	}

}

# update line and switch
$dbh->do("delete from switch where sw_id = '$dialerId'");
$dbh->do("delete from line where ln_switch = '$dialerId'");
$dbh->disconnect;

$ast->disconnect;

$log->debug("Terminating");
$log->fin;

exit;
