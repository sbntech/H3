#!/usr/bin/perl

# Notes:
# This script must be run on the asterisk box to ensure
# that all the timestamps use the same source. Localtime must be eastern
#
# the dialplan detects faxes as Human, I am accepting this for now 4/18
#
# Channels are uniquely identified by concat of Channel and Uniqueid
# Originations that fail to connect don't get "real" channels

use strict;
use warnings;
use lib '/home/grant/H3/convert';
use lib '/home/grant/H3/www/perl';
use DialerUtils;
use Logger;
use AstManager;
use DateTime;
use Time::HiRes qw( gettimeofday tv_interval usleep );

die "FATAL: projects voice prompts missing" unless (-d '/var/lib/asterisk/sounds/projects/_1');
die "FATAL: standard prompts missing" unless (-d '/var/lib/asterisk/sounds/sbn/StandardPrompts');

my $worker0 = '10.80.2.1'; 
my $hostname = `hostname`;
chomp($hostname);
my $dialerId = uc(substr($hostname,0,4));
$dialerId = 'WTST' if ($hostname eq 'swift');
my $GRAPHDAT = '/var/log/astdialer.dat';

# dynamic parameters (from switch table via SW_VoipCPS)
my $curPorts = 0;
my $o_gap = 0.05; # gap in seconds between originations

# static parameters
my $AgentCarrierID = 'B';
my $CarrierID;
my $MAXPORTS = 500;
my $outchan;
my $CarrierName = 'UNKNOWN';
if ($dialerId eq 'WTST') {
	$CarrierID = 'F';
	$outchan = 'sip/roadrunner/0555';
	$CarrierName = 'Tester F';
	$worker0 = 'localhost'; 
	$GRAPHDAT = "/dialer/www/fancy/asterisk.$dialerId.graph.dat";
} elsif ($dialerId eq 'W130') {
	$CarrierID = 'A';
	$outchan = 'sip/gcns/1';
	$CarrierName = 'GCNS A';
} else {
	print "\n\nNot a registered dialer name $dialerId\n";
	exit;
}


my $ONLYONE = 0; # to dial just one number on ine project set to 1

# attempt to start asterisk (no harm if it is already started)
system('/usr/sbin/asterisk');
sleep(1);

DialerUtils::daemonize();

my $log = Logger->new('/var/log/astdialer.log');

my $ast = new AstManager('sbnmgr', 'iuytfghd', 'localhost', 'on', $log);
$ast->check_limits();

my $db0 = DialerUtils::db_host(); 
my $dbh = DialerUtils::db_connect($db0);
my $o_time = [ gettimeofday() ]; # used to restrict the pace of originations
my $o_busy = 0; # carrier busy since last iteration
my $o_total = 0; # total calls since last iteration
my $usedPorts = 0;
my %stats = ( 'ProspectCalls' => 0, 'AgentCalls' => 0, 'Connects' => 0, 'Human' => 0, 'Duration' => 0 );
my @nullgraphstats = ( 
			'ProspectCalls' => 0, 
			'AgentCalls' => 0, 
			'Connects' => 0, 
			'Human' => 0, 
			'MaximumCPS' => 0, 
			'Duration' => 0 );
my %graphstats = @nullgraphstats;

# ITERPOINT - is the seconds after the top of the minute
	# when the once-per-minute routines are executed.
	# it is random so that when there are multiple dialers
	# the database is not whacked at the same time
my $ITERPOINT = int(rand(10)) + 4; 
my $nextIter = time();
my $nextGC = time() + 3600;

my %projects;

# %falseCB holds numbers that yielded carrier busy (possibly falsely)
my %falseCB;

sub init_dialer {

	# update table switch
	my $db = $dbh->selectrow_hashref("select SW_Number, SW_VoipCPS, SW_VoipPorts from switch where SW_ID = '$dialerId'");
	if ($db->{SW_Number}) {
		$dbh->do("update switch set SW_IP = 'ASTERISK', 
			SW_Status = 'A', SW_lstmsg = current_timestamp(), SW_Start = current_timestamp(),
			SW_callsuur = 0, SW_databaseSRV = '$CarrierName' where SW_ID ='$dialerId' and SW_Number = " . $db->{SW_Number} );
		$curPorts = $db->{'SW_VoipPorts'};
	} else {
		$dbh->do("insert into switch
			(SW_IP, SW_Status, SW_ID, SW_lstmsg, SW_start, SW_callsday, SW_callsuur, SW_databaseSRV, SW_VoipCPS, SW_VoipPorts) values
			('ASTERISK', 'A', '$dialerId', current_timestamp(), current_timestamp(), 0, 0, '$CarrierName', 0, 0)");
		$curPorts = 0;
	}

	# update table lines
	$dbh->do("delete from line where ln_switch = '$dialerId'");

	my $count = 0;
	my $ln_status = 'F';
	BOARD: for (my $board = 1; $board < 200; $board++) {
		for (my $chan = 1; $chan < 25; $chan++) {
			$count++;
			last BOARD if ($count > $MAXPORTS);
			$ln_status = 'B' if ($count > $curPorts);

			my $ln_line = "$dialerId-$board-$chan-$count";
			$dbh->do("insert into line 
				(ln_line, ln_switch, ln_board, ln_channel, ln_status, ln_ipnumber, ln_tasknumber, ln_dti, ln_voice, ln_action, ln_trunk, ln_PJ_Number, ln_priority,ln_reson,ln_lastused) values
 				('$ln_line', '$dialerId', '$board', '$chan', '$ln_status', 'ASTERISK', '$count', $count, 'Y', 0,'$CarrierID', 0, '1','Init', now())");
		}
	}

	$log->info("Database initialized with $count lines for $dialerId");
	reread_config();
}

sub graphing {

	my ($simul, $o_good, $dlm) = @_;

	if (open GRAPHDATA, '>>', $GRAPHDAT) {
		my $jnow = time() * 1000;
		print GRAPHDATA "[ $jnow, " .
				$graphstats{ProspectCalls} . ", " .
				$graphstats{AgentCalls} . ", " .
				$graphstats{Connects} . ", " .
				$graphstats{Human} . ", " .
				$graphstats{Duration} . ", " .
				$graphstats{MaximumCPS} . ", " .
				$curPorts . ", " .
				$usedPorts . ", " .
				$simul . ", " .
				$o_busy . ", " .
				$o_good . ", " .
				$dlm . ", " .
				" ],\n";
		close GRAPHDATA;
		%graphstats = @nullgraphstats;
	}
}

sub summarize {

	$log->info('SUMMARY: ' . scalar(keys %projects) . " projects.");
	my $totcache = 0;
	my $simul = 0;

	for my $pjnum (keys %projects) {
		my $pj = $projects{$pjnum};

		my $bsz = scalar(@{$pj->{'NumbersBuffer'}});
		my $asz = scalar(keys %{$pj->{'NumbersActive'}});
		$simul += $asz;
		$totcache += ($bsz + $asz);
		my $a = sprintf('pj=%5d bufsz=%4d targrate=%4d currate=%4d',
				$pjnum, $bsz, $pj->{'LineRate'}, $asz);

		if ($ast->{'running'} == 1) {
			$a .= ' NumbersActive=[';
			for my $num (keys %{$pj->{'NumbersActive'}}) { $a .= "$num," }
			$a .= ']';
		}

		my $b = 'Stats:';
		if (defined($pj->{'Statistics'})) {
			for my $d (keys %{$pj->{'Statistics'}}) {
				$b .= " $d=" . $pj->{'Statistics'}->{$d};
			}
		}

		$log->info("SUMMARY: $a $b");
	}
	my $o_good = $o_total - $o_busy;
	my $dlm = 0;
	$dlm = 60 * $o_good / $simul if $simul > 0;

	$log->info("SUMMARY: totcache=$totcache, curPorts=$curPorts, usedPorts=$usedPorts, simul=$simul, o_total=$o_total (" .
		sprintf('%5.2f', $o_total / 60) . "/sec), o_busy=$o_busy, o_good=$o_good, dials/lines/hr=$dlm");

	if ($ast->{'running'} == 1) {
		if ($totcache > 0) {
			$log->debug("Waiting for $totcache numbers to be processed, before terminating.");
		} else {
			$log->debug("Nothing left to dial, can stop now");
			$ast->{'running'} = 0;
		}
	}

	graphing($simul, $o_good, $dlm);
	$log->info('SUMMARY: done');

}

sub dialplan_context {
	# determines the correct dialplan context to use

	my $pj = shift;
	my $testcall = shift;

	if ($testcall eq 'Y') {
		if ($pj->{'PJ_Type2'} eq 'L') {
			return "pjtestL";
		} else {
			return "pjtestBoth";
		}
	} else {
		return "pjtype" . $pj->{'PJ_Type'} . $pj->{'PJ_Type2'};
	}
}

sub return_numbers {
	my $pj = shift;

	if (! defined($pj->{'NumbersBuffer'})) {
		$log->info("attempting to return numbers for project " .
				$pj->{'PJ_Number'} . "but the NumbersBuffer was not defined");
		return;
	}
	my $bsz = scalar(@{$pj->{'NumbersBuffer'}});
	return if $bsz == 0;

	$log->debug("cachesize=$bsz returning all $bsz numbers for project " . $pj->{'PJ_Number'});
	my ($rcount, $rmiss, $elapsed) =
		DialerUtils::dialnumbers_put($dbh, $pj->{'PJ_Number'}, $pj->{'NumbersBuffer'});

	$log->info("Project " . $pj->{'PJ_Number'} . 
		": cachesize=$bsz, numbers returned count=$rcount, rmiss=$rmiss in $elapsed seconds");
	$pj->{'NumbersBuffer'} = [];
}

sub update_project {
	my $pjrow = shift;
	my $LineRate = shift;

	if (defined($projects{$pjrow->{'PJ_Number'}})) {
		# a known project
		$LineRate = $projects{$pjrow->{'PJ_Number'}}->{'LineRate'} if (! defined($LineRate)); # testcall sample
		$log->debug("Updated project " . $pjrow->{'PJ_Number'} . ": line rate now " .
				"$LineRate was " . $projects{$pjrow->{'PJ_Number'}}->{'LineRate'});
		$projects{$pjrow->{'PJ_Number'}}->{'LineRate'} = $LineRate;
		# update these just in case they may have changed
		$projects{$pjrow->{'PJ_Number'}}->{'PJ_Type'} = $pjrow->{'PJ_Type'};
		$projects{$pjrow->{'PJ_Number'}}->{'PJ_Type2'} = $pjrow->{'PJ_Type2'};
		$projects{$pjrow->{'PJ_Number'}}->{'PJ_OrigPhoneNr'} = $pjrow->{'PJ_OrigPhoneNr'};

	} else {
		# a new project
		$LineRate = 1 if (! defined($LineRate)); # testcall sample
		$log->debug("New project " . $pjrow->{'PJ_Number'} . ": line rate set at $LineRate");
		
		my $CID = DialerUtils::determine_CID_for_project($dbh, $pjrow->{'PJ_OrigPhoneNr'},
			$pjrow->{'PJ_CustNumber'});
		if ((defined($pjrow->{'PJ_OrigPhoneNr'})) && ($pjrow->{'PJ_OrigPhoneNr'} ne $CID)) {
			$log->debug("Reseller default CID $CID used for project " .
				$pjrow->{'PJ_Number'});
		}

		$projects{$pjrow->{'PJ_Number'}} = {
			PJ_Number => $pjrow->{'PJ_Number'},
			PJ_Type => $pjrow->{'PJ_Type'},
			PJ_Type2 => $pjrow->{'PJ_Type2'},
			PJ_OrigPhoneNr => $CID,				
			LineRate => $LineRate, # number of simultaneous calls (lines) we should use
			NumbersBuffer => [ ], # array containing undialed numbers
			NumbersActive => {}, # hash (key=number) of hashes for numbers being used
					# Begin => timestamp, set in originate for prospects only
					# Testcall => flag indicating if it is a test call
		};
	}
}

sub originate_one_call {
	my $pjnum = shift;
	my $number = shift;
	my $callerid = shift;
	my $testcall = shift;

	if ((! defined($callerid)) || ($callerid !~ /\d{10}/)) {
		$log->debug("CALLER_ID: Project $pjnum has no caller id");
		$callerid = $ast->select_system_callerid($number);
	} else {
		# ensure the project callerid is interstate
		if ($ast->areacode2state(substr($callerid,0,3)) eq
				$ast->areacode2state(substr($number,0,3))) {
			$log->debug("CALLER_ID: Project $pjnum has caller id $callerid in the same"
				. " state (" . $ast->areacode2state(substr($callerid,0,3)) .
				") as the prospect number $number");
			$callerid = $ast->select_system_callerid($number);
		} else {
			$log->debug("CALLER_ID: using Project $pjnum caller id $callerid " .
				"for prospect number $number");
		}
	}

	my $pj = $projects{$pjnum};
	if (defined($pj->{'NumbersActive'}->{$number})) {
		$log->error("active call for $number on project $pjnum already, cannot originate again");
		return;
	}

	my ($secs, $msecs) = gettimeofday();
	my $now = sprintf("%d.%06d", $secs, $msecs);
	$pj->{'NumbersActive'}->{$number} = {
		Begin => $now,
		Testcall => $testcall
	};

	my $context = dialplan_context($pj, $testcall);
	my $aid = $ast->originate_action_id();
	my $chan = "$outchan$number";

	$ast->originate_basic($pjnum, $number, $pj->{'NumbersActive'}->{$number}, $chan, $CarrierID, 
		["ProspectNumber=$number", "PJ_Number=$pjnum" ],
		's', '1', $context, $callerid, 32, $aid, 300);
}

sub testcalls {

	my $res = $dbh->selectall_arrayref("select * from line 
				where ln_switch = '$dialerId' and ln_action = '777777'",
				{ Slice => {}});

	for my $tc (@$res) {
		my ($PJ_Type, $PJ_Type2, $PJ_PhoneCallC, $PJ_OrigPhoneNr, $TestPhone, $PJ_Number, $X_Type) = split(';', $tc->{'ln_info'});

		$log->info("TESTCALL: PJ_Number=$PJ_Number, PJ_Type=$PJ_Type, PJ_Type2=$PJ_Type2, PJ_PhoneCallC=$PJ_PhoneCallC, PJ_OrigPhoneNr=$PJ_OrigPhoneNr, TestPhone=$TestPhone, X_Type=$X_Type");

		my $pj = $dbh->selectrow_hashref("select * from project where
			PJ_Number = $PJ_Number");

		if (! defined($pj->{'PJ_Number'})) {
			$log->error("received a testcall request for non-existant project [$PJ_Number]");
		} else {
			update_project($pj, undef);
			if ($X_Type eq 'S') {
				# sample
				push @{$projects{$pj->{'PJ_Number'}}->{'NumbersBuffer'}}, $TestPhone;
			} else {
				# test
				originate_one_call($pj->{'PJ_Number'}, $TestPhone, $PJ_OrigPhoneNr, 'Y');
			}
		}

		$dbh->do("update line set 
						ln_status = if(ln_status = 'B','B','F'), 
						ln_lastused=current_timestamp(), 
						ln_PJ_Number = 0, 
						ln_action = 0, 
						ln_info = ''
						where ln_switch = '$dialerId' and id = " . $tc->{'id'});
	}		

}

sub reread_config {

	my $sw = $dbh->selectrow_hashref("select SW_VoipCPS from switch where SW_ID = '$dialerId'");

	# Calls Per Second
	if ((defined($sw->{'SW_VoipCPS'})) && ($sw->{'SW_VoipCPS'} > 0)) {
		$o_gap = 1 / ($sw->{'SW_VoipCPS'});
		$graphstats{MaximumCPS} = $sw->{'SW_VoipCPS'};
	} else {
		$o_gap = 600;
		$graphstats{MaximumCPS} = 0;
		$log->warn("SW_VoipCPS was not defined (or <= zero) in the switch table for SW_ID = $dialerId");	
	}

}

sub look_for_work {

	if ($ast->{'running'} > 1) {
		$log->debug("LOOKING: looking for work starts");
	} else {
		$log->debug("LOOKING: not looking for work - we are stopping");
		for my $pjnum (keys %projects) {
			$projects{$pjnum}->{'LineRate'} = 0;
			return_numbers($projects{$pjnum});
		}
		$curPorts = 0;
		$usedPorts = 0;
		return;
	}

	if (($o_total > 10) && ($o_busy == $o_total)) {
		$log->fatal("all $o_total originations returned carrier busy, stopping");
		$ast->{'running'} = 2 if $ast->{'running'} > 2;
		return;
	}

	# stop lines where necessary - preserving blocked status as needed
	my $aff = $dbh->do("update line set 
							ln_status = if(ln_status = 'B','B','F'), 
							ln_lastused = now(), 
							ln_PJ_Number = 0, 
							ln_action = 0, 
							ln_info = ''
						where ln_switch = '$dialerId'
							and (ln_action = 888888 or 
								 ln_action = 999999)");
	$log->debug("LOOKING: $aff lines were stopped in the database");
	
	# accept new work
	$aff = $dbh->do("update line set 
							ln_status = 'U', 
							ln_lastused=current_timestamp(), 
							ln_PJ_Number = ln_action, 
							ln_action = 0, 
							ln_info = '' 
						where ln_status = 'F' and ln_switch = '$dialerId'
							and ln_action > 0 and ln_action < 777777");
	$log->debug("LOOKING: $aff new work lines were started in the database");

	# how many free lines? 
	my $rref = $dbh->selectrow_hashref(
		"select count(*) as LinesFree from line 
		where ln_switch = '$dialerId' and ln_status = 'F'"); 
	$log->debug("LOOKING: " . $rref->{'LinesFree'} . " lines free");

	# scan the database and update %projects 
	my $aref = $dbh->selectall_arrayref(
		"select ln_PJ_Number, count(*) as LineRate, 
		PJ_Type, PJ_Type2, PJ_OrigPhoneNr, PJ_Number, PJ_CustNumber
		from line, project 
		where ln_PJ_Number = PJ_Number and ln_switch = '$dialerId'
			and ln_status = 'U' and ln_PJ_Number > 0
		group by ln_PJ_number", { Slice => {}});

	my %actives;
	$usedPorts = 0;
	for my $pjrow (@$aref) {
		$actives{$pjrow->{'ln_PJ_Number'}} = 1;
		$usedPorts += $pjrow->{'LineRate'};
		update_project($pjrow, $pjrow->{'LineRate'});
	}

	$curPorts = $rref->{'LinesFree'} + $usedPorts;

	# projects that are stopping
	for my $pjnum (keys %projects) {
		my $pj = $projects{$pjnum};

		if (! defined($actives{$pj->{'PJ_Number'}})) {
			$log->info("LOOKING: stopping project $pjnum: line rate set to 0");
			$pj->{'LineRate'} = 0;
			return_numbers($pj);
		}
	}


	# load more numbers into the cache for each active project
	for my $pjnum (keys %projects) {
		my $pj = $projects{$pjnum};

		next if $pj->{'LineRate'} == 0; 

		my $DIALS_PER_LINE_PER_ITERATION = 6;
		my $cachesize = int(($pj->{'LineRate'} * $DIALS_PER_LINE_PER_ITERATION) + 1);
		my $nums_needed = $cachesize - scalar(@{$pj->{'NumbersBuffer'}});

		if ($ONLYONE == 1) {
			# for testing can dial just one number
			$nums_needed = 1; # ONE@TIME
			$ast->{'running'} = 1; # ONE@TIME
		}

		if ($nums_needed > 0) {
			# fill the cache with $nums_needed more numbers
			$log->debug("LOOKING: numbers needed for project $pjnum: $nums_needed");
			my ($actual, $elapsed) =
				DialerUtils::dialnumbers_get($dbh, $pjnum, $CarrierID, $nums_needed, $pj->{'NumbersBuffer'});
			$log->debug("LOOKING: project $pjnum has " . scalar(@{$pj->{'NumbersBuffer'}}) .
				" numbers cached now (retrieved $actual more, in $elapsed seconds)");
		}
	}

	# check for and remove projects that have nothing left to do
	for my $pjnum (keys %projects) {
		my $pj = $projects{$pjnum};
		my $bsz = scalar(@{$pj->{'NumbersBuffer'}});
		my $asz = scalar(keys %{$pj->{'NumbersActive'}});

		if (($bsz == 0) && ($asz == 0)) {
			# we cannot get numbers for the project AND
			# we don't have any active ones
			$log->info("LOOKING: project=$pjnum is finished for now");
			$dbh->do("update line set 
					ln_status = 'F', 
					ln_info = '', 
					ln_PJ_Number = 0, 
					ln_action = 0,
					ln_AG_Number = 0,
					ln_lastused = now()
					where ln_switch = '$dialerId' and ln_PJ_Number = $pjnum");
			delete $projects{$pjnum};
		}
	}

	$log->debug("LOOKING: looking for work ends");
}

sub originate {
	return unless $ast->{'running'} == 3;

	my $now = [gettimeofday()];
	my $elapsed = tv_interval($o_time, $now);
	return if ($elapsed < $o_gap);

	# we originate once every short while - we need the gaps otherwise the
	# carrier returns lots of HC34 : No Circuit/Channel Available.
	# we find the most needy project to originat on

	my $perc = 1.0;
	my $chosen;
	my $pj;
	for my $pjnum (keys %projects) {
		$pj = $projects{$pjnum};
		next if $pj->{'LineRate'} == 0;

		my $bz = scalar(@{$pj->{'NumbersBuffer'}});
		next if $bz == 0;

		my $az = scalar(keys %{$pj->{'NumbersActive'}});
		next if $az >= $pj->{'LineRate'};

		my $ratio = $az / $pj->{'LineRate'};
		if ($ratio < $perc) {
			# the most needy is the one with lowest
			# percent
			$chosen = $pjnum;
			$perc = $ratio;
		}
	} # for

	if (defined($chosen)) {
		$pj = $projects{$chosen};
		my $number = pop @{$pj->{'NumbersBuffer'}};
		originate_one_call($chosen, $number, $pj->{'PJ_OrigPhoneNr'}, 'N');
		$o_time = $now;
		$o_total++;
	}

}

sub get_agentchannel_id {
	my $event = shift;
	
	if (defined($event->{'destuniqueid'})) {
		return $event->{'destuniqueid'};
	} else {
		$log->error("dial event without a destuniqueid - halting");
		$ast->{'running'} = 2;
	}
}

sub dial_handler {
	my $event = shift;

	# dial events are the way that we learn about dials related to the prospect call
	# channel => has the prospect channel
	# destination => has the new call (probably for an agent)
	
	my $chanId = $event->{'uniqueid'};
	my $c = $channels{$chanId};
	my $orig;
	my $oaid = 'unknown';

	if (defined($c)) {
		if (defined($c->{'Variables'}{'OriginateActionId'})) {
			$oaid = $c->{'Variables'}{'OriginateActionId'}{'Value'};
			$orig = $originations{$oaid};
		} else {
			$log->warn("dial event on a channel $chanId without an OriginateActionId");
			return;
		}

		if (!defined($orig)) {
			$log->warn("dial event on a channel $chanId with OriginateActionId $oaid " .
				" but could not find that origination");
			return;
		}

		my $PJ_Number = $orig->{'PJ_Number'};
		if (!defined($PJ_Number)) {
			$log->warn("dial event on a channel $chanId with OriginateActionId $oaid " .
				" but PJ_Number is not defined there");
			return;
		}
			
		my $ProspectNumber = $orig->{'PhoneNumber'};
		if (!defined($ProspectNumber)) {
			$log->warn("dial event on a channel $chanId with OriginateActionId $oaid " .
				" but PhoneNumber is not defined there");
			return;
		}
			
		if (defined($event->{'subevent'})) {
			if ($event->{'subevent'} eq 'Begin') {
				my $agchanId = get_agentchannel_id($event);
				$log->debug( "DIAL: to agent from $chanId to $agchanId dialstring=" . $event->{'dialstring'});

				$channels{$agchanId} = { 
					'Id' => $agchanId,
					'BridgedTo' => $chanId,
					'DialString' => $event->{'dialstring'}};
				$channels{$agchanId}{'States'}{'0'} = 
					{ 'Desc' => 'New', 'Timestamp' => $event->{'timestamp'} };
				$channels{$chanId}->{'BridgedTo'} = $agchanId;

				# set some variables for the agents channels ...
				$ast->send_action("SetVar", {
					'Channel'	=> $event->{'destination'}, # want to set it on the agent channel
					'Variable'	=> 'PJ_Number',
					'Value'		=> $PJ_Number
					},{ });
				$ast->send_action("SetVar", {
					'Channel'	=> $event->{'destination'}, # want to set it on the agent channel
					'Variable'	=> 'ProspectNumber',
					'Value'		=> $ProspectNumber
					},{ });
				$ast->send_action("SetVar", {
					'Channel'	=> $event->{'destination'}, # want to set it on the agent channel
					'Variable'	=> 'DYNAMIC_FEATURES',
					'Value'		=> 'AgentDNC'
					},{ });

			} else {
				$log->debug("DIAL: ignoring this event with subevent=" . $event->{'subevent'});
				return;
			}
		} else {
			$log->fatal("dial event without a subevent");
		}
	} else {
		$log->error("unexpected dial event, it is on an old channel that is unknown.");
	}
}

################################################################
sub statistics {

	my $col1 = '';
	$col1 = sprintf('%6d (%3d%%)', $stats{Connects}, int(100*$stats{Connects}/$stats{ProspectCalls})) if ($stats{ProspectCalls} > 0);
	my $col2 = '';
	$col2 = sprintf('%6d (%3d%%)', $stats{Human}, int(100*$stats{Human}/$stats{Connects})) if ($stats{Connects} > 0);
	my $col3 = '';
	my $mach = $stats{Connects} - $stats{Human};
	$col3 = sprintf('%6d (%3d%%)', $mach, int(100*$mach/$stats{Connects})) if ($stats{Connects} > 0);
	my $col4 = '';
	my $fail = $stats{ProspectCalls} - $stats{Connects};
	$col4 = sprintf('%6d (%3d%%)', $fail, int(100*$fail/$stats{ProspectCalls})) if ($stats{ProspectCalls} > 0);
	my $col5 = '';
	$col5 = int($stats{Duration} / $stats{Human}) if $stats{Human} > 0;
	my $col6 = '';
	$col6 = int($stats{Duration} / $stats{AgentCalls}) if (defined($stats{AgentCalls})) && ($stats{AgentCalls} > 0);

	$log->info("STATISTICS: ProspectCalls=" . $stats{ProspectCalls} . ", AgentCalls=" . $stats{AgentCalls} . 
		", Durations=" . $stats{Duration} . " secs, Connects=$col1, Human=$col2, Machine=$col3, Non-Conn=$col4, sec/live=$col5, sec/P1= $col6");

}
                                                                                                                    
################################################################
sub result_callback {
	my ($actionid, $orig, $chan) = @_;

	my $pjnum = $orig->{'PJ_Number'};
	my $pj = $projects{$pjnum};
	my $num = $orig->{'PhoneNumber'};

	# --------- Prospect Call ---------
	my $cdr = AstManager::prep_prospect_cdr($chan, $orig, $pj->{'PJ_Type2'}, $dialerId);
	$ast->append_cdr($cdr);

	my $disposition = $cdr->{'Disposition_Code'};
	my $answeredBy = $cdr->{'Answered_By'};
	my $duration = $cdr->{'Duration'};

	if ($answeredBy ne 'NoAnswer') {
		$graphstats{'Connects'}++;
		$stats{'Connects'}++;
		if ($answeredBy eq 'Machine') {
			$pj->{'Statistics'}->{'Machine'}++;
		} else { # Human|TestCall|Undetected
			$graphstats{'Human'}++;
			$stats{'Human'}++;
			$pj->{'Statistics'}->{'Human'}++;
		}
	} else {
		if (($disposition eq 'BU') && ($cdr->{'Extra_Info'} =~ /CB$/)) {
			$o_busy++;
			# TODO previously we added this for retry (nice if it was sent to another carrier)
		}
	}

	$pj->{'Statistics'}->{'ProspectCalls'}++;
	$pj->{'Statistics'}->{$disposition}++;
	$stats{'ProspectCalls'}++;
	$stats{'Duration'} += $duration;
	$graphstats{'ProspectCalls'}++;
	$graphstats{'Duration'} += $duration;

	# --------- Agent Call ---------
	if (defined($chan->{'BridgedTo'})) {
		my $AgentNumber;
		if (defined($chan->{'Variables'}{'AgentNumber'})) {
			$AgentNumber = $chan->{'Variables'}{'AgentNumber'}{'Value'};
		}
		my $AgentId;
		if (defined($chan->{'Variables'}{'AgentId'})) {
			$AgentId = $chan->{'Variables'}{'AgentId'}{'Value'};
		}

		# determine disposition, duration, etc...
		$stats{'AgentCalls'}++;
		$graphstats{'AgentCalls'}++;
		$disposition = 'AB';
		$duration = 0;
		my $achan = $channels{$chan->{'BridgedTo'}};
		if (defined($achan)) {

			delete $channels{$chan->{'BridgedTo'}};

			my $extra;
			my $circuit = "C-$AgentCarrierID";
			if (defined($achan->{'Variables'}{'HangupCause'})) {
				$extra = "HC" . $achan->{'Variables'}{'HangupCause'}{'Value'};
			} else {
				$extra = "HCx";
			}

			$disposition = $achan->{'DispositionCode'};
			$duration = $achan->{'BillableDuration'};
			if ($disposition eq 'OK') {
				$disposition = 'AC';
			} elsif ($disposition eq 'NA') {
				$disposition = 'AN';
			} else {
				$disposition = 'AB';
			}

			$graphstats{'Duration'} += $duration;

			$ast->append_cdr({
					'PJ_Number' => $pjnum,
					'CDR_Time' => $achan->{'ResultTimestamp'},
					'Called_Number' => $AgentNumber,
					'DNC_Flag' => 'N',
					'Duration' => $duration,
					'Disposition_Code' => $disposition,
					'Dialer_Id' => $dialerId,
					'Circuit' => $circuit,
					'Extra_Info' => $extra,
					'Related_Number' => $num,
					'Survey_Response' => '',
					'Agent_Number' => $AgentId });

			$pj->{'Statistics'}->{'AgentCalls'}++;
			$pj->{'Statistics'}->{$disposition}++;

			DialerUtils::disconnect_agent($dbh,$pjnum,$AgentId);
		} else {
			$log->error("prospect has a BridgedTo value but it is missing in %channels");
		}
	}

	# --------- clean up ---------
	delete $pj->{'NumbersActive'}->{$num};
}

sub timeout_callback {
	my ($actionid, $orig, $chan) = @_;

	$o_busy++;

	my $r = $orig->{'Reference'}; # originate_basic checks that it is defined
	my ($pj, $pjnum, $num) = 
		($projects{$orig->{'PJ_Number'}}, $orig->{'PJ_Number'}, $orig->{'PhoneNumber'});

	$ast->append_cdr({
				'PJ_Number' => $pjnum,
				'CDR_Time' => $chan->{'ResultTimestamp'},
				'Called_Number' => $num,
				'DNC_Flag' => 'N',
				'Duration' => 0,
				'Disposition_Code' => 'EC',
				'Dialer_Id' => $dialerId,
				'Circuit' => 'None',
				'Extra_Info' => 'ERR480',
				'Related_Number' => '', # no related number
				'Survey_Response' => '',
				'Agent_Number' => 9999 });

	$pj->{'Statistics'}->{'ProspectCalls'}++;
	$pj->{'Statistics'}->{'EC'}++;

	delete $pj->{'NumbersActive'}->{$num};
}

sub exit_handler {
	$log->info("signal caught: STOPPING");
	$ast->{'running'} = 2;
	$nextIter = time() - 10;
}

# +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++ main

$SIG{INT} = \&exit_handler;
$SIG{QUIT} = \&exit_handler;
$SIG{TERM} = \&exit_handler;

init_dialer();
$ast->load_AREACODE_STATE();

open(PID, ">", "/var/run/astdialer.pid");
print PID $$;
close(PID);

$log->debug("Event loop starts (ITERPOINT=$ITERPOINT)");
graphing(0,0,0); # graph zeroes

while ($ast->{'running'} > 0) {
	my $nowt = time();

	if ($nextGC < $nowt) {
		%falseCB = ();
		$nextGC = time() + 3600;
	}

	if ($nextIter < $nowt) {
		$log->debug("MARK: starts");
		testcalls();
		$ast->flush_cdrs($worker0);
		reread_config();
		look_for_work();
		$ast->foreign_channels();
		statistics(); 
		$log->debug("MARK: ends");
	}

	$ast->check_completions(\&timeout_callback, \&result_callback);
		
	originate();

	if ($nextIter < $nowt) {

		summarize();

		$o_busy = 0;
		$o_total = 0;
		$nextIter = $nowt - ($nowt % 60) + 60 + $ITERPOINT;
	}

	if ($ast->{'running'} > 0) {
		$ast->handle_events(\&originate,
			{ 
			  'dial' => \&dial_handler,
			});
	}

	if ($ast->{'running'} == 2) {
		$dbh->do("update switch set sw_status = 'E' where sw_id = '$dialerId'");
		$dbh->do("delete from line where ln_switch = '$dialerId'");
		$ast->{'running'} = 1;
	}
}

$ast->flush_cdrs($worker0);

# return numbers 
for my $pjnum (keys %projects) {
	return_numbers($projects{$pjnum});
}

# update line and switch
$dbh->do("update switch set sw_status = 'E' where sw_id = '$dialerId'");
$dbh->do("delete from line where ln_switch = '$dialerId'");
$dbh->disconnect;

$ast->disconnect;

graphing(0,0,0);
graphing(0,0,0); # second time is to graph zeroes
statistics();
$log->debug("Terminating");
$log->fin;

exit;
