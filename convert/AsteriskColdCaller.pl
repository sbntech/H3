#!/usr/bin/perl

# Notes:
# This script must be run on the asterisk box to ensure
# that all the timestamps use the same source. Localtime must be eastern
#
# Channels are uniquely identified by concat of Channel and Uniqueid
# Originations that fail to connect don't get "real" channels
#
# Dynamic queues are avoided now since they seem likely to be an IO burden since they are re-read every Queue command

use strict;
use warnings;
use lib '/home/grant/H3/convert';
use lib '/home/grant/H3/www/perl';
use DialerUtils;
use Logger;
use AstManager;
use DateTime;
use Messenger;
use LWP;
use HTTP::Request::Common qw( GET POST );
use Time::HiRes qw( gettimeofday tv_interval usleep );

my @sysCallerIds = ('8042349010', '2402107143');
my $CARRFACTOR = 1.07; # factor covering the gap between our duration calc and the carrier's

# attempt to start asterisk (no harm if it is already started)
system('/usr/sbin/asterisk');
sleep(2);

my $rstatsDir = '/root/realtime_stats';
system("mkdir -p $rstatsDir");

DialerUtils::daemonize();

my $log = Logger->new('/var/log/astcoldcaller.log');
my $mq = Messenger::end_point();

my $ast = new AstManager('sbnmgr', 'iuytfghd', 'localhost', 'on', $log);
$ast->check_limits();

my $o_gap = 0.2; # gap in seconds between originations
my $o_time = [ gettimeofday() ]; # used to restrict the pace of originations

my $worker0 = '10.80.2.1'; 
my $hostname = `hostname`;
chomp($hostname);
my $dialerId = 'COLD';
if ($hostname eq 'swift') {
	$worker0 = 'localhost';
	$o_gap = 10;
}

my $dbh = DialerUtils::db_connect();
my $useragent = LWP::UserAgent->new;

# WEBROOT/agents/<SESSION_ID>/{popupdata,status}
# WEBROOT/projects/<PROJECT_ID>/...
my $WEBROOT = '/home/grant/webroot';

# %agents stores info about agents
my %agents;

# %transfers stores info about transfers
my %transfers;

# %masquerades stores info for transfer
my %masquerades;

# %projectQs stores info about projects and queues since there is a 1-1 between queues and projects
my %projectQs;

my $REALTIME_STATS_HEADER = "<html><head><link rel=\"stylesheet\" TYPE=\"text/css\" href=\"/glm.css\"></head><body>\n";
my $REALTIME_STATS_FOOTER = "<script>setTimeout('location.reload()',3000);</script>
</body></html>\n";

my $AgentCarrier = 'Z';
my $Carrier = 'Z';
my $ChannelTech = 'sip/roadrunner/0555';
my $agent_chantech = 'sip/roadrunner/0555';

if ($ARGV[0] eq 'A') {
	$Carrier = 'A';
	$ChannelTech = 'sip/gcns/1';

	$AgentCarrier = 'A';
	$agent_chantech = 'sip/gcns/1';
}

sub agent_desc {
	my $ag = shift;

	my $pq = $projectQs{$ag->{'AG_Project'}};
	my $pjcust = '[MISSING CUSTOMER INFO]';

	if (defined($pq)) {
		$pjcust = sprintf('Project %s [%s] of Customer %s [%s]',
			$pq->{'PJ_Number'}, $pq->{'PJ_Description'},
			$pq->{'CO_Number'}, $pq->{'CO_Name'});
	}

	return sprintf("Agent %s [%s - %s] on $pjcust", $ag->{'AG_Number'}, $ag->{'AG_Name'}, $ag->{'AG_CallBack'});

}

sub return_numbers {
	my $pjq = shift;

	my @nums = keys %{$pjq->{'NumbersCache'}};
	my $bsz = scalar(@nums);

	if ($bsz > 0) {
		my ($rcount, $rmiss, $elapsed) = 
			DialerUtils::dialnumbers_put($dbh, $pjq->{'PJ_Number'}, \@nums);
		$log->info("Project " . $pjq->{'PJ_Number'} . 
			": cachesize=$bsz, numbers returned count=$rcount, rmiss=$rmiss in $elapsed seconds");
	} else {
		$log->info("Project " . $pjq->{'PJ_Number'} . " has no numbers to return.");
	}

	delete $pjq->{'NumbersCache'};
}

sub pjq_halting {
	my $pjq = shift;
	my $reason = shift;


	$pjq->{'HaltingReason'} = $reason;
	my $pjnum = $pjq->{'PJ_Number'};

	# return numbers
	return_numbers($pjq);

	# force Active agents off
	for my $anum (keys %agents) {
		my $a = $agents{$anum};
		next unless ($a->{'AG_Project'} == $pjnum);

		force_agent_off($a, "Project is halting [$reason]")
	}

	$dbh->do("update project set PJ_timeleft = '$reason'
		where PJ_Number = $pjnum");

	$log->info("Project $pjnum has halted: $reason");

	# realtime stats page
	my ($nowd, $nowt) = DialerUtils::local_datetime();
	my $sname = uc($pjq->{'PJ_Description'});
	$sname =~ tr/0-9A-Z//cd;
	my $fname = "/tmp/$pjnum-$sname-CC.html";
	open PJFILE, '>', $fname or die "failed to open $fname: $!";
	print PJFILE "$REALTIME_STATS_HEADER" . $pjq->{'PJ_Description'} .
		" halted $nowd $nowt: $reason<script>
			setTimeout('location.reload()',60000);</script>
			</body></html>";
	close PJFILE;
	system("mv $fname $rstatsDir");

	# delete the memory
	delete $projectQs{$pjnum};
}

sub prediction_adjustment {

	for my $pjnum (keys %projectQs) {
		my $q = $projectQs{$pjnum};

		if ($q->{'QueueAbandoned'} > $q->{'QAbandonCheckpoint'}) {
			$q->{'PredictionFactor'} -= 0.05 if $q->{'PredictionFactor'} > 0.2;
			$q->{'QAbandonCheckpoint'} = $q->{'QueueAbandoned'};
		} else {
			$q->{'PredictionFactor'} += 0.001 if $q->{'PredictionFactor'} < 0.9;
		}
	}

}

sub update_AgentCounts {
	my $pjnum = shift;

	my $total = 0;
	my %histo = (
		'Active' => 0,
		'Paused' => 0,
		'Connected' => 0 );
	for my $anum (keys %agents) {
		my $a = $agents{$anum};
		next unless ($a->{'AG_Project'} == $pjnum);

		$total++;
		$histo{$a->{'Status'}}++;
	}

	return (\%histo, $total);
}

sub numbers_maint {
	my $nowt = shift;
	

	for my $pjnum (keys %projectQs) {
		my $q = $projectQs{$pjnum};

		my $acount = 0;
		($q->{'AgentCounts'}, $acount) = update_AgentCounts($pjnum);

		if ($acount == 0) {
			pjq_halting($q, 'Shutdown in progress');
			next;
		}

		my $agentsActive = $q->{'AgentCounts'}{'Active'};
		my $agentsConnected = $q->{'AgentCounts'}{'Connected'};

		if ($q->{'HaltingReason'} ne '') {
			next;
		}

		if ($agentsActive + $agentsConnected == 0) {
			# queue has no members ready yet
			next;
		}

		if ($q->{'NextCacheRefill'} > $nowt) {
			# not time for this project to refill
			next;
		}
		$q->{'NextCacheRefill'} = $nowt + 60;

		# we want to fetch numbers in big chunks
		my $cacheSize = scalar(keys %{$q->{'NumbersCache'}});

		if ($cacheSize < 400 ) {
			# fetch 500 more
			my @numbers;
			my ($actual,$elapsed) = 
				DialerUtils::pjnumbers_get($dbh, $pjnum, 500, \@numbers);
			$log->debug("pjnumbers_get: $actual numbers in $elapsed seconds for project $pjnum. cacheSize=" . sprintf('%d', $cacheSize + $actual));

			for my $n (@numbers) {
				my ($Num, $BestCarriers, $AltCarriers) = @$n;
				$q->{'NumbersCache'}{$Num} = {
					'BestCarriers' => $BestCarriers,
					'AltCarriers' => $AltCarriers };
			}
				
		}

		$cacheSize = scalar(keys %{$q->{'NumbersCache'}});
		if ($cacheSize == 0) { # no more numbers in the timezones allowed
			
			if ($agentsConnected == 0) {
				# halt if there are no connected agents
				pjq_halting($q, 'No numbers');
			}

			$log->debug("No more numbers for project $pjnum");
		}

	}
}

sub pop_number {
	my $pjq = shift;

	for my $n (keys %{$pjq->{'NumbersCache'}}) {
		delete $pjq->{'NumbersCache'}{$n};
		return $n;
	}

	return undef;
}

sub look_for_work {

	if ($ast->{'running'} > 1) {
		$log->debug("LOOKING: looking for work starts");
	} else {
		$log->debug("LOOKING: not looking for work - we are stopping");
		return;
	}

	# flag agents so we can tell which are stopping
	for my $k (keys %agents) {
		$agents{$k}{'UpdateFlag'} = 0;
	}

	# agents are logged into our projects
	# (A project is runnable if the allocator decided it was runnable.)
	my $aref = $dbh->selectall_arrayref(
		"select * from agent 
			left join project on AG_Project = PJ_Number
			where length(AG_SessionId) > 5 
			and AG_Status = 'A'
			and AG_MustLogin = 'Y'
			and PJ_Type = 'C' 
			and (PJ_timeleft = 'Running*' or PJ_timeleft = 'No agents ready')", { Slice => {}});

	for my $agdb (@$aref) {

		my $agloc = $agents{$agdb->{'AG_Number'}};

		if (defined($agloc)) {
			my $desc = agent_desc($agloc);
			# we previously knew about this agent
			if ($agloc->{'AG_Project'} != $agdb->{'AG_Project'}) {
				# agent switched projects!
				force_agent_off($agloc, "$desc just switched projects!");
			} else {
				$agloc->{'UpdateFlag'} = 1;
			}
		} else {

			# populate $agents{$agdb->{'AG_Number'}}
			$agents{$agdb->{'AG_Number'}} = {
				'AG_Number' => $agdb->{'AG_Number'}, # back ref
				'Status' => 'New',
				'UpdateFlag' => 1,
				'Calls'			=> 0,
				'CallDuration'	=> 0,
				'Waits'			=> 0,
				'WaitDuration'	=> 0,
				'LoginTimestamp'	=> [gettimeofday()]
			};

			for my $c (keys %$agdb) {
				$agents{$agdb->{'AG_Number'}}->{$c} = $agdb->{$c};
			}
			$agloc = $agents{$agdb->{'AG_Number'}};

			if (! defined($projectQs{$agloc->{'AG_Project'}})) {
				# a new project 
				$projectQs{$agloc->{'AG_Project'}} = { 
					'DialingCount' => 0,
					'StartTimestamp'	=> [gettimeofday()],
					'CallGap' => 0, 			# represents the call rate for this project
					'LastCall' => 0,			# timestamp of the most recent call
					'CallCount' => 0,			# total calls made
					'HumanCount' => 0,			# connects identified as Lives
					'MachineCount' => 0,		# connects identifies as Machines
					'QueueAbandoned' => 0,		# counts of QueueCallerAbandon events
					'QAbandonCheckpoint' => 0,	# snapshot of QueueAbandoned
					'PredictionFactor' => 0.85,	# ratio to ideal handling rate we are trying to achieve
					'AgConnCount' => 0,			# count of Agent Connects
					'AgConnDuration' => 0,		# sum of agent call durations
					'AgAveCallLength' => 0,		# calculated, stored for display
					'AgConnRatio' => 0,			# calculated, stored for display
					'IdealHandlingRate' => 0,	# calculated, stored for display
					'TargetDialingRate' => 0,	# calculated, stored for display
					'NumbersCache' => {},		# stores numbers
					'NextCacheRefill' => 0,		# time the cache is to attempt a refill

					'HaltingReason' => '',
					'AgentCounts' => { 
							'New' 		=> 0, # agent is sbn logged in and needs to be called
							'Called' 	=> 0, # an origination started for an agent
							'Waiting' 	=> 0, # an agent logged in but has not yet called in
							'Active' 	=> 0, # asterisk logged in and a member of queue ready for calls
							'Connected'	=> 0, # agent bridged to prospect
						}
				};

				# populate some database data
				my $aref = $dbh->selectrow_hashref(
					"select * from project 
						left join customer on PJ_CustNumber = CO_Number
						left join reseller on CO_ResNumber = RS_Number
						where PJ_Number = " . $agloc->{'AG_Project'});

				for my $c (keys %$aref) {
					$projectQs{$agloc->{'AG_Project'}}{$c} = $aref->{$c};
				}

				my $CID = DialerUtils::determine_CID_for_project($dbh, $aref->{'PJ_OrigPhoneNr'},
					$aref->{'PJ_CustNumber'});
				if ((defined($aref->{'PJ_OrigPhoneNr'})) && ($aref->{'PJ_OrigPhoneNr'} ne $CID)) {
					$log->debug("Reseller default CID $CID used for project " .
						$aref->{'PJ_Number'});
				}
				$projectQs{$agloc->{'AG_Project'}}{'PJ_OrigPhoneNr'} = $CID;

				$log->info("Project " . $agloc->{'AG_Project'} .
					" has been created.");

			}

			my $desc = agent_desc($agloc);
			$log->info("$desc just logged in (ref: $agloc)");

		}
	}

	# agents that are stopping
	my $count = 0;
	for my $anum (keys %agents) {
		my $ag = $agents{$anum};
		if ($ag->{'UpdateFlag'} > 0) {
			$count++;
			next;
		}
		my $desc = agent_desc($ag);

		$log->info("$desc is stopping");

		delete $agents{$anum};
	}

	$log->debug("LOOKING: looking for work ends, $count agents are on board.");
}

sub call_an_agent {

	my $called = 0;

	for my $anum (keys %agents) {
		my $ag = $agents{$anum};
		next unless ($ag->{'Status'} eq 'New');

		my $desc = agent_desc($ag);

		# determine $chan
		my $carr;
		my $chan;
		if ($ag->{'AG_CallBack'} eq 'call-in') {
			$ag->{'CDR_Number'} = '0000000000';
			$ag->{'Status'} = 'Waiting';
			$log->info("$desc needs to call in");
			next;
		} elsif (substr($ag->{'AG_CallBack'},0,4) eq 'sip:') {
			$chan = 'sip/' . substr($ag->{'AG_CallBack'},4);
			$carr = 'X'; # direct sip

			# turn the sip address into a 10 digit number for the cdr
			my $num = substr($ag->{'AG_CallBack'},4,100);
			$num =~ s/([^\@]*)\@.*/$1/;
			$num =~ s/[^0-9]/0/g;
			$num = substr($num,0,10);
			$num .= substr('0000000000', 0, 10 - length($num));
			$ag->{'CDR_Number'} = $num;
		} else {
			$chan = $agent_chantech . $ag->{'AG_CallBack'};
			$carr = 'Z'; # apn
			$ag->{'CDR_Number'} = $ag->{'AG_CallBack'};
		}
		my $aid = $ast->originate_action_id();

		$o_time = [gettimeofday()];
		$called = 1;
		$ast->originate_basic($ag->{'AG_Project'}, $ag->{'AG_CallBack'}, $ag, $chan, $carr,
			[ "AG_Number=$anum" ],
			's', '1', 'callagent', $sysCallerIds[0], 32, $aid, 0);
		$log->info("$desc called via $chan aid=$aid");
		$ag->{'Status'} = 'Called';
		$ag->{'OriginateActionId'} = $aid;

		last if ($carr eq 'Z'); # only want to call one agent at a time so as not to flood the carrier
	}

	return $called;
}

sub originate {

	return unless $ast->{'running'} == 3;

	my $now = [gettimeofday()];
	my $elapsed = tv_interval($o_time, $now);
	return if ($elapsed < $o_gap);

	return if (call_an_agent() > 0); 

	my @candidates;

	PROJECT: for my $pjnum (keys %projectQs) {
		my $q = $projectQs{$pjnum};

		my $all = 0;
		($q->{'AgentCounts'}, $all) = update_AgentCounts($pjnum);
		my $agentsActive = $q->{'AgentCounts'}{'Active'};
		my $agentsConnected = $q->{'AgentCounts'}{'Connected'};
		my $agentsPaused = $q->{'AgentCounts'}{'Paused'};
		my $totalAgents = $agentsActive + $agentsConnected + $agentsPaused;

		# calculate average length of agent call incl setup
		if ($q->{'AgConnCount'} == 0) {
			$q->{'AgAveCallLength'} = 0;
		} else {
			$q->{'AgAveCallLength'} = ($q->{'AgConnDuration'} / $q->{'AgConnCount'});
		}

		# calculate agent connect ratio
		if ($q->{'CallCount'} == 0) {
			$q->{'AgConnRatio'} =  0;
		} else {
			$q->{'AgConnRatio'} =  $q->{'AgConnCount'} /  $q->{'CallCount'};
		}

		# calculate ideal handling rate (calls per hour)
		if ($q->{'AgAveCallLength'} == 0) {
			$q->{'IdealHandlingRate'} = 0;
		} else {
			$q->{'IdealHandlingRate'} = $totalAgents * (3600 / $q->{'AgAveCallLength'});
		}

		# calculate target dialing rate (calls per hour)
		$q->{'CallGap'} = 0;
		if ($q->{'AgConnRatio'} == 0) {
			$q->{'TargetDialingRate'} = 0;
		} else {
			$q->{'TargetDialingRate'} = $q->{'PredictionFactor'} * ($q->{'IdealHandlingRate'} / $q->{'AgConnRatio'});

			if ($q->{'TargetDialingRate'} > 0) {
				$q->{'CallGap'} = 3600 / $q->{'TargetDialingRate'}; # in seconds
			}
		}

		if ($totalAgents == 0) {
			# project has no agents left
			next PROJECT;
		}

		# if the project has only a few agents OR long agent calls then don't predict
		if ((($totalAgents <= 4) || ($q->{'AgAveCallLength'} > 120)) && ($agentsActive == 0)) {
				# all agents are connected, so ...
				next PROJECT;
		}

		my $is_candidate = 0;

		if ($q->{'AgConnCount'} >= 3) {
			# use fancy prediction algorithm

			if ($q->{'CallGap'} == 0) {
				next PROJECT;
			}

			# calculate gap since LastCall and see if we should originate
			$elapsed = tv_interval($q->{'LastCall'}, $now);
			if (($q->{'DialingCount'} > 0) && ($elapsed < $q->{'CallGap'})) {
				next PROJECT;
			}

			$is_candidate = 1;

		} else {
			# use basic prediction algorithm
			my $PredictiveRatio = 3;

			if ($q->{'DialingCount'} < $agentsActive * $PredictiveRatio) {
				$is_candidate = 1;
			}
		}


		if ($is_candidate) {
			push @candidates, { 'PJ_Number' => $pjnum, 
				'Ready_Ratio' => $agentsActive / $totalAgents,
				};
		}
	} # end of for loop PROJECT

	my @scand = sort { $b->{'Ready_Ratio'} <=> $a->{'Ready_Ratio'} } @candidates;

	my $q;
	my $num;
	my $pjnum;

	PJQ: while (scalar(@scand) > 0) {
		my $pjcand = shift @scand;
		$pjnum = $pjcand->{'PJ_Number'};
		$q = $projectQs{$pjnum};
		$num = pop_number($q);
		if (defined($num)) {
			last;
		}
	}

	return unless defined($num); # no projects have nubmers

	# originate a call for $q & $num 
	# determine $chan
	my $chan = $ChannelTech . $num;
	my $aid = $ast->originate_action_id();
	my $context = 'pjtypeC' . $q->{'PJ_Type2'};

	my $callerid = $q->{'PJ_OrigPhoneNr'};
	if ((! defined($callerid)) || ($callerid !~ /\d{10}/)) {
		$callerid = $ast->select_system_callerid($num);
		$log->debug("CALLER_ID: Project $pjnum has no caller id, chose system: $callerid");
	} else {
		# ensure the project callerid is interstate
		if ($ast->areacode2state(substr($callerid,0,3)) eq
				$ast->areacode2state(substr($num,0,3))) {
			$log->debug("CALLER_ID: Project $pjnum has caller id $callerid in the same"
				. " state (" . $ast->areacode2state(substr($callerid,0,3)) .
				") as the prospect number $num");
			$callerid = $ast->select_system_callerid($num);
		} else {
			$log->debug("CALLER_ID: using Project $pjnum caller id $callerid " .
				"for prospect number $num");
		}
	}

	$q->{'ListOriginations'}{$num} = 1;
	$q->{'LastCall'} = [gettimeofday()];

	$o_time = $now;
	$ast->originate_basic($pjnum, $num, $q, $chan, $Carrier, 
		[ "QueueName=pjq$pjnum", "ProspectNumber=$num", "PJ_Number=$pjnum", "PJ_Record=" . $q->{'PJ_Record'} ],
		's', '1', $context, $callerid, 32, $aid, 3600);

	$q->{'DialingCount'}++; # keeps track of prediction
}

sub exit_handler {
	$log->info("signal caught: STOPPING");
	$ast->{'running'} = 2;
}

sub force_agent_off {
	my $ag = shift;
	my $msg = shift;

	$msg = 'unknown' unless defined $msg;

	my $desc = agent_desc($ag);
	
	$dbh->do("update agent set 
					AG_QueueReady = 'N',
					AG_Paused = 'N',
					AG_BridgedTo = null, 
					AG_Lst_change = now(), 
					AG_SessionId = null
				where AG_Number = " . $ag->{'AG_Number'});

	my $dur = 0;

	if (defined($ag->{'CDR_Begin'})) {
		# send a cdr
		$dur = time() - int($ag->{'CDR_Begin'});
		my $cdr = {
				'PJ_Number' => $ag->{'AG_Project'},
				'CDR_Time' => time(),
				'Called_Number' => $ag->{'CDR_Number'},
				'DNC_Flag' => 'N',
				'Duration' => $dur,
				'Disposition_Code' => 'AS',
				'Dialer_Id' => $dialerId,
				'Circuit' => "C-$AgentCarrier",
				'Extra_Info' => 'Standby-OFF',
				'Related_Number' => '', # no related number
				'Survey_Response' => '',
				'Agent_Number' => $ag->{'AG_Number'} };

		$ast->append_cdr($cdr);
		delete $ag->{'CDR_Begin'};
	}

	# unpause to (asterisk remembers that you were paused)
	$ast->send_action('QueuePause', { 'Paused' => 'false', 'Interface' => "Agent/" . $ag->{'AG_Number'} });
	$ast->send_action('AgentLogoff', { 'Agent' => $ag->{'AG_Number'} });
	delete $agents{$ag->{'AG_Number'}}; # using the back ref

	$log->debug("Agent $desc being forced off and deleted. Dur: $dur Reason: $msg");
}

sub result_callback {
	my ($actionid, $orig, $chan) = @_;

	# $r is a referece to $projectQs{$pjnum}
	my $r = $orig->{'Reference'}; # originate_basic checks that it is defined

	if (defined($r->{'AG_Number'})) {
		# call to agent
		force_agent_off($r, "Got regular call completion for the agent");
	} else {
		# prospect call has finished ...
		my $cdr = AstManager::prep_prospect_cdr($chan, $orig, $r->{'PJ_Type2'}, $dialerId);
		$ast->append_cdr($cdr);

		# number removed from ListOriginations and ListQueued
		my $num = $orig->{'PhoneNumber'};
		my $q = $projectQs{$r->{'PJ_Number'}};
		delete $q->{'ListOriginations'}{$num}; 
		delete $q->{'ListQueued'}{$num};

		# some accounting for the prediction algorith
		$q->{'CallCount'}++;
		if (substr($cdr->{'Disposition_Code'},0,1) eq 'H') {
			$q->{'HumanCount'}++;
		} elsif (substr($cdr->{'Disposition_Code'},0,1) eq 'M') {
			$q->{'MachineCount'}++;
		}

		# increment DialingCount?
		if (! defined($chan->{'Variables'}{'BRIDGEPEER'})) {
			# prospect never spoke to agent
			my $q = $projectQs{$r->{'PJ_Number'}};
			if (defined($q)) {
				$q->{'DialingCount'}-- if ($q->{'DialingCount'} > 0);
			} else {
				$log->warn("bad project " . $r->{'PJ_Number'} . " number referenced");
			}
		}
	}
}

sub timeout_callback {
	my ($actionid, $orig, $chan) = @_;

	my $r = $orig->{'Reference'}; # originate_basic checks that it is defined

	if (defined($r->{'AG_Number'})) {
		# call to agent was hungup
		force_agent_off($r, "Got a timeout on the agent channel");
	} else {
		# prospect
		my $cdr = AstManager::prep_prospect_cdr($chan, $orig, $r->{'PJ_Type2'}, $dialerId);
		$ast->append_cdr($cdr);

		my $q = $projectQs{$r->{'PJ_Number'}};

		# some accounting for the prediction algorith
		$q->{'CallCount'}++;

		# number removed from ListOriginations and ListQueued
		my $num = $orig->{'PhoneNumber'};
		delete $q->{'ListOriginations'}{$num}; 
		delete $q->{'ListQueued'}{$num}; # unlikely to be defined

		# decrement DialingCount
		if (defined($q)) {
			$q->{'DialingCount'}-- if ($q->{'DialingCount'} > 0);
		} else {
			$log->warn("bad project number referenced");
		}
	}
}

sub QueueCallerAbandon_ehandler {
	my $event = shift;
	# event ==> QueueCallerAbandon, holdtime=28, originalposition=2, position=2, privilege=agent,all, queue=pjq43628, timestamp=1251219505.552185, uniqueid=1251219464.2,

	my $pjnum = substr($event->{'queue'},3,10);
	my $q = $projectQs{$pjnum};

	$q->{'QueueAbandoned'}++;

}

sub agentlogin_ehandler {
	my $event = shift;
	# event ==> Agentlogin, agent=1, channel=SIP/10.10.10.4-01544198, 
	#		privilege=agent,all, timestamp=1246905128.671282, uniqueid=1246905117.0

	if (defined($event->{'agent'})) {
		my $ag = $agents{$event->{'agent'}};
		if (defined($ag)) {
			# make status Active
			my $desc = agent_desc($ag);
			$ag->{'CDR_Begin'} = $event->{'timestamp'};

			my $aff = $dbh->do("update agent set 
							AG_QueueReady = 'Y',
							AG_BridgedTo = null, 
							AG_Lst_change = now() 
						where 
							AG_Status != 'B' and 
							AG_SessionId is not null and 
							AG_Number = " . $ag->{'AG_Number'});

			if ($aff > 0) {
				$log->info("$desc logged in and made QueueReady");
				$ag->{'Status'} = 'Active';
				$ag->{'Interface'} = $event->{'channel'}; # for pausing
				$ag->{'LoginTimestamp'}	= [gettimeofday()];

				my $chanId = $event->{'uniqueid'};
				my $c = $channels{$chanId};

				if (!defined($c)) {
					$log->error("unexpected agentlogin event on a channel that is unknown.");
				}
				
			} else {
				$log->warn("$desc logged in but failed to make QueueReady, forcing off");
				force_agent_off($ag, "Unable to make queue ready");
			}
		} else {
			$log->error("Agent login for unknown agent " . $event->{'agent'});
		}
	} else {
		my $s = event_tostring($event);
		$log->error("Agent login without an Agent: $s");
	}

}

sub agentlogoff_ehandler {
	my $event = shift;
	# event ==> Agentlogoff, agent=1, logintime=99, 
	#   privilege=agent,all, timestamp=1246905227.555449, uniqueid=1246905117.0

	if (defined($event->{'agent'})) {
		my $ag = $agents{$event->{'agent'}};
		if (defined($ag)) {
			force_agent_off($ag, "Got AgentLogoff event");
		} else {
			# perhaps the agent was just forced-off (can happen when project runs out of numbers)
			$log->info("Agent logoff for unknown agent " . $event->{'agent'});
		}
	} else {
		my $s = event_tostring($event);
		$log->error("Agent logoff without an Agent: $s");
	}
		
}

sub chan2agent {
	my $chan = shift;

	return unless defined $chan;
	return unless substr($chan,0,6) eq 'Agent/';

	my $a = 1 * substr($chan,6,99);

	return unless $a > 0;

	return $a;
}

sub dump_agent {
	my $AgentId = shift;
	if ($AgentId > 0) {
		my $ag = $agents{$AgentId};

		if (defined($ag)) {
			my $dump = "--- dump agent $AgentId ---\n";

			for my $k (sort keys %$ag) {
				$dump .= "$k : ";
				if (defined($ag->{$k})) {
					$dump .= $ag->{$k};
				} else {
					$dump .= "UNDEFINED";
				}
				$dump .= "\n";
			}
			$log->debug($dump);
		} else {
			$log->warn("agent $AgentId not found, cannot dump it");
		}
	} else {
		$log->warn("AgentId=[$AgentId] is nonsense, cannot dump it");
	}
}

sub dial_ehandler {
	my $event = shift;

	return unless defined($event->{'destuniqueid'}); # ignore dialstatus type events

	# tracks dials for transfers - they occur on Local channels
	if ($event->{'channel'} =~ /Local\/(\d{10})\@callagent-(.*);(1|2)/) {
		my ($exten,$uid,$pairnum) = ($1,$2,$3);
		my $key = "Local/$exten\@callagent-$uid";

		if (!defined($transfers{$key})) {
			$log->error("dial event for transfer without a proper transfer");
		} else {
			# record the channel
			my $chanId = $event->{'destuniqueid'};
			my $c = $channels{$chanId};

			if (!defined($c)) {
				$log->error("Dial event on unknown destination channel");
				return;
			}

			$c->{'TransferKey'} = $key;
			$transfers{$key}{'ThirdPartyChanId'} = $chanId;
			$transfers{$key}{'Local2ChanId'} = $event->{'uniqueid'};
			$log->debug("transfer dialing $exten on $chanId recorded");
		}
		
	} else {
		$log->warn("dial event was unexpected - odd channel syntax");
	}
}

sub check_message_queue {
	# hangup, nextcall, logoff, transfer

	my $messages = $mq->pop_messages;

	for my $msg (@$messages) {
		$log->debug("MQUEUE: received JSON--> $msg");
		my $params = JSON::from_json($msg);

		next unless scalar(@$params) > 3;
		my ($command, $pjid, $agid, $phnum, $xferTo)  = @$params;
		$log->debug("MQUEUE: Parsed command $command: pjid=$pjid, agid=$agid, phnum=$phnum");

		if ($command eq 'hangup') {
			# determine the channel, from the phone number ...
			my $orig = AstManager::find_origination_from_phnr($phnum);

			if (defined($orig)) {
				if (defined($orig->{'ChannelId'})) {
					$log->debug("MQUEUE: execute hangup on channel: " . $orig->{'ChannelId'});
					$ast->send_action('Hangup',
						{ 'Channel' => $orig->{'ChannelId'} });
				} else {
					$log->warn("MQUEUE: hangup aborted, undefined channel");
				}
			} else {
				$log->warn("MQUEUE: hangup aborted, cannot find origination");
			}
		} elsif ($command eq 'nextcall') {
			# hangup first? ... do not hangup if 3rd party transfer has occurred
			my $xfer = find_transfer('ProspectNumber' => $phnum);
			if (! defined($xfer)) {
				my $orig = AstManager::find_origination_from_phnr($phnum);

				if (defined($orig)) {
					if (defined($orig->{'ChannelId'})) {
						$log->debug("MQUEUE: execute nextcall-hangup on channel: " . $orig->{'ChannelId'});
						$ast->send_action('Hangup',
							{ 'Channel' => $orig->{'ChannelId'} });
					} else {
						$log->warn("MQUEUE: nextcall-hangup aborted, undefined channel");
					}
				} else {
					$log->warn("MQUEUE: nextcall-hangup aborted, cannot find origination");
				}
			}

			my $interface = "Agent/$agid";
			$log->debug("MQUEUE: executing queuepause (unpause) on interface: $interface for agent $agid");
			$ast->send_action('QueuePause', { 'Paused' => 'false', 'Interface' => $interface });
			$dbh->do("update agent set AG_Lst_change = current_timestamp(), AG_Paused = 'N'
				where AG_Number = $agid");
			$agents{$agid}->{'Status'} = 'Active';
		} elsif ($command eq 'logoff') {
			$log->debug("MQUEUE: logoff of agent $agid");
			$ast->send_action('AgentLogoff', { 'Agent' => $agid });
		} elsif ($command eq 'transfer') {
			my $n = DialerUtils::north_american_phnumber($xferTo);
			if ((defined($n)) && ($n =~ /^\d{10}$/)) {

				my $orig = AstManager::find_origination_from_phnr($phnum);

				if (defined($orig)) {
					if (defined($orig->{'ChannelId'})) {
						my $agchan = $agents{$agid}->{'Interface'};
						$log->debug("MQUEUE: execute transfer of prospect ($phnum talking to agent $agid) to $n (agchan=$agchan)");

						$ast->send_action('Atxfer', {
							'Channel' => $agchan, # agent channel
							'Context' => 'xferAgent', 'Exten' => $xferTo, 'Priority' => '1' });

					} else {
						$log->warn("MQUEUE: transfer aborted, undefined prospect channel");
					}
				} else {
					$log->warn("MQUEUE: transfer aborted, cannot find origination");
				}
			} else {
				$log->warn("MQUEUE: transfer failed, ($xferTo) is not a valid phone number");
			}
		}
	}

}

sub find_transfer {
	my ($key, $val) = @_;

	for my $xkey (keys %transfers) {
		my $xfer = $transfers{$xkey};

		if ($xfer->{$key} eq $val) {
			return $xfer;
		}
	}

	return undef;
}

sub check_completed_transfers {

	# check for completed transfers
	TRANSFER: for my $xkey (keys %transfers) {
		my $xfer = $transfers{$xkey};

		# has ThirdPartyChanId hangup?
		my ($tpChan, $tpSinceHangup) = $ast->is_channel_hungup($xfer->{'ThirdPartyChanId'});
		next TRANSFER unless $tpSinceHangup > 3;

		# has MasqChanId hangup or aborted transfer?
		my ($pchan, $pSinceHangup) = $ast->is_channel_hungup($xfer->{'MasqChanId'});
		if (defined($pchan)) {
			next TRANSFER unless ($pSinceHangup > 1);
		}

		# this transfer is complete so ...
		my $dumpstr = '';
		for my $k (keys %$xfer) {

			my $val = $xfer->{$k};
			$val = 'UNDEFINED' unless defined($val);

			$dumpstr .= "$k: $val\n";
		}
		$log->debug("Transfer complete:\n$dumpstr");
		
		# cdr for ThirdPartyChanId
		$ast->calculate_durations($xfer->{'ThirdPartyChanId'});
		AstManager::determine_callresult($xfer->{'ThirdPartyChanId'}, 5);
		my $xfercdr = {
				'PJ_Number' => $xfer->{'PJ_Number'},
				'CDR_Time' => $tpChan->{'ResultTimestamp'},
				'Called_Number' => $xfer->{'Transfer_To'},
				'DNC_Flag' => 'N',
				'Duration' => $tpChan->{'BillableDuration'},
				'Disposition_Code' => 
					$tpChan->{'DispositionCode'} eq 'OK' ? 'AC' : $tpChan->{'DispositionCode'},
				'Dialer_Id' => $dialerId,
				'Circuit' => "C-$AgentCarrier",
				'Extra_Info' => 'AG' . $xfer->{'AG_Number'},
				'Related_Number' => $xfer->{'ProspectNumber'},
				'Survey_Response' => '',
				'Agent_Number' => '1111' };
		$ast->append_cdr($xfercdr);
		delete $channels{$xfer->{'ThirdPartyChanId'}};

		# cdr for the MasqChanId
		if (defined($pchan)) { # would not be defined in aborted xfer
			$ast->calculate_durations($xfer->{'MasqChanId'});
			AstManager::determine_callresult($xfer->{'MasqChanId'}, 5);
			my $pcdr = {
					'PJ_Number' => $xfer->{'PJ_Number'},
					'CDR_Time' => $pchan->{'ResultTimestamp'},
					'Called_Number' => $xfer->{'ProspectNumber'},
					'DNC_Flag' => 'N',
					'Duration' => $pchan->{'BillableDuration'},
					'Disposition_Code' => 
						$pchan->{'DispositionCode'} eq 'OK' ? 'HA' : $pchan->{'DispositionCode'},
					'Answered_By' => 'Human',
					'Dialer_Id' => $dialerId,
					'Circuit' => "C-$Carrier",
					'Extra_Info' => 'AXFER',
					'Related_Number' => '', # no related number
					'Survey_Response' => '',
					'Agent_Number' => 9999 };
			$ast->append_cdr($pcdr);
			delete $channels{$xfer->{'MasqChanId'}}
		}

		delete $transfers{$xkey};

	} # TRANSFER	
}

sub varset_ehandler {
	my $event = shift;

	if ((! defined($event->{'variable'})) || (! defined($event->{'value'}))) {
		$log->warn("VarSet unexpectedly has no variable|value, ignoring it");
		return;
	}

	# TRANSFERERNAME handling
	if ($event->{'variable'} eq 'TRANSFERERNAME') {
		# create the transfers element
		if ($event->{'channel'} =~ /Local\/(\d{10})\@callagent-(.*);(1|2)/) {
			my ($exten,$uid,$pairnum) = ($1,$2,$3);
			my $key = "Local/$exten\@callagent-$uid";

			if (defined($transfers{$key})) {
				$log->warn("VarSet TRANSFERERNAME occured for a second time on the same chan");
			} else {
				if ($event->{'value'} =~ /Agent\/(\d*)/) {
					my $agnum = $1;
					my $ag = $agents{$agnum};

					if (!defined($ag)) {
						$log->error("agent not found in transfer");
						return;
					}

					if (!defined($ag->{'BridgedTo'})) {
						$log->error("agent transfer, but the agent is not bridged to anything");
						return;
					}

					if (!defined($ag->{'BridgedTo'}{'OriginationId'})) {
						$log->error("agent transfer, but the agent->BridgedTo origination id is not defined");
						return;
					}

					my $orig = $originations{$ag->{'BridgedTo'}{'OriginationId'}};

					if (!defined($orig)) {
						$log->error("agent transfer, but the bridgedTo origination id ("
							. $ag->{'BridgedTo'}{'OriginationId'} . ") was not valid");
						return;
					}

					if (!defined($ag->{'BridgedTo'}{'ProspectChanId'})) {
						$log->error("agent transfer, but the BridgedTo prospect chanId is not defined");
						return;
					}

					if (!defined($ag->{'BridgedTo'}{'AgentChanId'})) {
						$log->error("agent transfer, but the BridgedTo agent chanId is not defined");
						return;
					}

					$transfers{$key} = {
						'AG_Number' => $agnum, 
						'PJ_Number' => $orig->{'PJ_Number'},
						'ProspectNumber' => $orig->{'PhoneNumber'},
						'Transfer_To' => $exten,
						'Local1ChanId' => $event->{'uniqueid'},
						'Local2ChanId' => undef, # set in dial event
						'OriginalProspectChanId' => $ag->{'BridgedTo'}{'ProspectChanId'},
						'AgentChanId' => $ag->{'BridgedTo'}{'AgentChanId'},
						'MasqChanId' => undef,
						'ThirdPartyChanId' => undef, # set by dial event
						'Verified' => 0, # gets verified by varset SBNAgentTransfer
					};
					$log->debug("Transfer by agent $agnum to $exten - " .
							" for prospect at " . $orig->{'PhoneNumber'});
				} else {
					$log->warn("VarSet TRANSFERERNAME has bogus value, skipping it");
				}
			}
		} else {
			$log->warn("VarSet TRANSFERERNAME on unexpected channel, skipping it");
		}
	} elsif ($event->{'variable'} eq 'SBNAgentTransfer') {
		# verifies the transfer
		if ($event->{'channel'} =~ /Local\/(\d{10})\@callagent-(.*);(1|2)/) {
			my ($exten,$uid,$pairnum) = ($1,$2,$3);
			my $key = "Local/$exten\@callagent-$uid";

			if (!defined($transfers{$key})) {
				$log->error("VarSet SBNAgentTransfer without a proper transfer");
			} else {
				if ($transfers{$key}{'Transfer_To'} eq $event->{'value'}) {
					$transfers{$key}{'Verified'} = 1;
					$log->debug("Transfer to $exten - verified [$key]");
				} else {
					$log->error("Failed to verify transfer with key=$key, " .
						"expected Transfer_To to be " . $event->{'value'} .
						" but it was " . $transfers{$key}{'Transfer_To'});
				}
			}
		} else {
			$log->warn("VarSet SBNAgentTransfer on unexpected channel, skipping it");
		}
	}
}

sub hangup_ehandler {
	my $event = shift;

	my $chanId = $event->{'uniqueid'};
	my $c = $channels{$chanId};
	if (defined($c)) {
		if ($event->{'channel'} =~ /(Transfered\/)?(Agent|SIP|Local)\/(.*)/) {
			my ($pre, $tech, $cid) = ($1, $2, $3);
			if ($tech eq 'Agent') {
				# hangup on channel Agent/NNNN is used to mark the point where an agent goes back 
				# to standby (end of bridge to prospect), prospect could be transferred though so 
				# not necessarily end of prospect call

				my $AgentId = chan2agent($event->{'channel'});

				# create the agent connected CDR
				my $ag = $agents{$AgentId};
				if (! defined($ag)) {
					$log->error("Not a known agent [$AgentId] in unlink event");
					return;
				}

				my $CDRtime = int($event->{'timestamp'});

				DialerUtils::disconnect_agent($dbh, $ag->{'AG_Project'}, $AgentId);

				# calculate the duration from bridge to unlink
				my $agdur = 1 + int($event->{'timestamp'} - $ag->{'CDR_Begin'});
				if ($agdur > 5000) {
					$log->error("AC duration error. timestamp=" . $event->{'timestamp'} .
						"  CDR_Begin=" . $ag->{'CDR_Begin'} . "  yielding duration=" .
						$agdur . "  (Correcting it)");
					$agdur = 24;
				}
				
				my $q = $projectQs{$ag->{'AG_Project'}};
				$q->{'AgConnCount'}++;
				$q->{'AgConnDuration'} += $agdur;

				my $agcdr = {
						'PJ_Number' => $ag->{'AG_Project'},
						'CDR_Time' => $CDRtime,
						'Called_Number' => $ag->{'CDR_Number'},
						'DNC_Flag' => 'N',
						'Duration' => $agdur,
						'Disposition_Code' => 'AC',
						'Dialer_Id' => $dialerId,
						'Circuit' => "C-$AgentCarrier",
						'Extra_Info' => 'Working',
						'Related_Number' => $ag->{'AG_BridgedTo'},
						'Survey_Response' => '',
						'Agent_Number' => $AgentId };

				$ast->append_cdr($agcdr);

				# reset the beginning for the AS cdr to come
				$ag->{'CDR_Begin'} = $event->{'timestamp'};
				if ($ag->{'Status'} ne 'Active') {
					$log->debug("pausing agent $AgentId (was " . $ag->{'Status'} , ")");
					$ag->{'Status'} = 'Paused';
				}
				$ag->{'Calls'}++;
				$ag->{'CallDuration'} += $agdur;
				$ag->{'AG_BridgedTo'} = undef;
				$ag->{'BridgedTo'} = undef;

				delete $channels{$chanId}; # since it is not deleted in AstManager

			} elsif ($tech eq 'Local') {
			} elsif ($tech eq 'SIP') {
				if (defined($c->{'TransferKey'})) {
					my $xfer = $transfers{$c->{'TransferKey'}};

					if (defined($xfer)) {
						$log->debug("Transfer hangup: ChanId=$chanId");
					} else {
						$log->warn('TransferKey=' . $c->{'TransferKey'} . ' is not a valid transfer');
					}
				}
			} else {
				# non-Agent hangup
			}
		} else {
			$log->error("channel string did not parse: [" . $event->{'channel'} . "]");
		}
	}
}

sub getProspect_chanId {
	my $chanId = shift;

	if (! defined($channels{$chanId})) {
		$log->error("prospect channel $chanId that is not in \%channels"); 
		return undef;
	}
	my $prospectChan = $channels{$chanId};

	my $orig;
	my $oaid;
	if (defined($prospectChan->{'Variables'}{'OriginateActionId'})) {
		$oaid = $prospectChan->{'Variables'}{'OriginateActionId'}{'Value'};
		$orig = $originations{$oaid};
	} else {
		$log->error("prospect channel $chanId without an OriginateActionId");
		return undef;
	}

	return {
		'Channel' => $prospectChan,
		'Origination' => $orig
	};
}

sub join_ehandler {
	my $event = shift;

	# numbers move from ListOriginations to ListQueued

	my $chanId = $event->{'uniqueid'};
	my $p = getProspect_chanId($chanId);
	if (!defined($p)) {
		$log->error("unable to determine the prospect channel in the event:\n"
			. event_tostring($event));
		return;
	}

	my $pjnum = substr($event->{'queue'},3,10);
	my $q = $projectQs{$pjnum};
	my $num = $p->{'Origination'}{'PhoneNumber'};

	delete $q->{'ListOriginations'}{$num};
	$q->{'ListQueued'}{$num} = 1;

	$log->debug("$num on $chanId joined queue for project $pjnum, in position "
		. $event->{'position'} . " Count=" . $event->{'count'});
}

sub leave_ehandler {
	my $event = shift;

	# numbers remove from ListQueued
	my $chanId = $event->{'uniqueid'};
	my $p = getProspect_chanId($chanId);
	if (!defined($p)) {
		$log->error("unable to determine the prospect channel in the event:\n"
			. event_tostring($event));
		return;
	}

	my $pjnum = substr($event->{'queue'},3,10);
	my $q = $projectQs{$pjnum};
	my $num = $p->{'Origination'}{'PhoneNumber'};

	delete $q->{'ListOriginations'}{$num}; # should be undef since deleted on join
	delete $q->{'ListQueued'}{$num};

	$log->debug("$num on $chanId left queue for project $pjnum, Count=" . $event->{'count'});

}

sub masquerade_ehandler {
	my $event = shift;

	# Masquerade, clone=SIP/roadrunner-00000001, clonestate=Up, original=Transfered/SIP/roadrunner-00000001, originalstate=Up, privilege=call,all, timestamp=1265064391.152650,

	my $clone = $event->{'clone'};

	if (! defined($clone)) {
		$log->error("Masquerade without a clone value");
		return;
	}

	$masquerades{$clone}{'Original'} = $event->{'original'};
	$masquerades{$clone}{'Timestamp'} = $event->{'timestamp'};
	$masquerades{$clone}{'Step'} = 0;

	$log->debug("Masquerade[step 0] ($clone) recorded");
}

sub rename_ehandler {
	my $event = shift;
	#event ==> Rename, channel=SIP/roadrunner-00000001, newname=SIP/roadrunner-00000001<MASQ>, privilege=call,all, timestamp=1265064391.152665, uniqueid=1265064358.1, 
	#event ==> Rename, channel=Transfered/SIP/roadrunner-00000001, newname=SIP/roadrunner-00000001, privilege=call,all, timestamp=1265064391.152674, uniqueid=1265064391.6,               	
	#event ==> Rename, channel=SIP/roadrunner-00000001<MASQ>, newname=Transfered/SIP/roadrunner-00000001<ZOMBIE>, privilege=call,all, timestamp=1265064391.152825, uniqueid=1265064358.1, 

	if (defined($masquerades{$event->{'channel'}})) {
		# step 1
		if ($masquerades{$event->{'channel'}}{'Step'} == 0) {
			$masquerades{$event->{'channel'}}{'Step'} = 1;
			$masquerades{$event->{'channel'}}{'OldChanId'} = $event->{'uniqueid'};
			$log->debug("Masquerade[step 1] (" . $event->{'channel'} . ") OldChanId = " . $event->{'uniqueid'});
		} else {
			$log->warn("rename event appears out of sequence, expected 0");
		}
	} elsif (defined ($masquerades{$event->{'newname'}})) {
		#step 2
		if ($masquerades{$event->{'newname'}}{'Step'} == 1) {
			$masquerades{$event->{'newname'}}{'Step'} = 2;
			$masquerades{$event->{'newname'}}{'NewChanId'} = $event->{'uniqueid'};
			$log->debug("Masquerade[step 2] (" . $event->{'newname'} . ") NewChanId = " . $event->{'uniqueid'});
		} else {
			$log->warn("rename event appears out of sequence, expected 1");
		}
	} else {
		my $key = $event->{'channel'};
		if ($key =~ s/(.*)<MASQ>/$1/) {
			# step 1
			if ($masquerades{$key}{'Step'} == 2) {
				$masquerades{$key}{'Step'} = 3;
				$log->debug("Masquerade[step 3] ($key) " . $masquerades{$key}{'OldChanId'} 
								. " was morphed to " . $masquerades{$key}{'NewChanId'});

				# mark the start of the call (esp for cdr recording)
				$channels{$masquerades{$key}{'NewChanId'}}{'States'}{'6'}{'Timestamp'} = 
						$event->{'timestamp'};

				# Find the transfer ...
				for my $xkey (keys %transfers) {
					my $xfer = $transfers{$xkey};

					if ($masquerades{$key}{'OldChanId'} eq $xfer->{'OriginalProspectChanId'}) {
						$log->debug("Masquerade $key relates to transfer " .
								$xfer->{'OriginalProspectChanId'});
						$xfer->{'MasqChanId'} = $masquerades{$key}{'NewChanId'};
					}
				}
				
				delete $masquerades{$key};
			} else {
				$log->warn("rename event appears out of sequence, expected 2");
			}
		} else {
			$log->warn("rename event is mysterious");
		}
	}

}

sub agentconnect_ehandler {
	my $event = shift;

	# event ==> AgentConnect, bridgedchannel=1264198534.2, channel=Agent/1, holdtime=1, member=Agent/1, membername=Agent/1, privilege=agent,all, queue=pjq2, ringtime=0, timestamp=1264198535.283187, uniqueid=1264198533.1, 

	# note: the bridge is between the SIP prospect channel and the AGENT agent channel, not the SIP agent channel
	my $pchanId = $event->{'uniqueid'};
	my $bchanId = $event->{'bridgedchannel'};

	my $a = $event->{'member'};

	my $AgentId = 0;
	if (index($a,'Agent/') == 0) {
		$AgentId = substr($a,6,15);
	}
	my $ag = $agents{$AgentId};
	if (! defined($ag)) {
		$log->error("AgentConnect for an unknown agent");
		return;
	}
	my $desc = agent_desc($ag);

	if (! defined($channels{$pchanId})) {
		$log->error("AgentConnect to a channel $pchanId that is not in \%channels");
	}
	if (! defined($channels{$bchanId})) {
		$log->error("AgentConnect to agent channel $bchanId that is not in \%channels");
	}

	my $prospectChan = $channels{$pchanId};
	my $orig;
	my $oaid;
	if (defined($prospectChan)) {
		if (defined($prospectChan->{'Variables'}{'OriginateActionId'})) {
			$oaid = $prospectChan->{'Variables'}{'OriginateActionId'}{'Value'};
			$orig = $originations{$oaid};
		} else {
			$log->error("AgentConnect event on a channel $pchanId without an OriginateActionId");
			return;
		}
	} else {
		$log->error("unable to determine the prospect channel in the event:\n"
			. event_tostring($event));
		return;
	}

	my $r = $orig->{'Reference'}; # originate_basic checks that it is defined

	# create the agent stand-by CDR
	my $dur = int($event->{'timestamp'} - $ag->{'CDR_Begin'});
	my $cdr = {
			'PJ_Number' => $r->{'PJ_Number'},
			'CDR_Time' => int($event->{'timestamp'}),
			'Called_Number' => $ag->{'CDR_Number'},
			'DNC_Flag' => 'N',
			'Duration' => $dur,
			'Disposition_Code' => 'AS',
			'Dialer_Id' => $dialerId,
			'Circuit' => "C-$AgentCarrier",
			'Extra_Info' => 'Standby',
			'Related_Number' => '', # no related number
			'Survey_Response' => '',
			'Agent_Number' => $AgentId };

	$ast->append_cdr($cdr);
	# reset the beginning for the AC cdr to come
	$ag->{'CDR_Begin'} = $event->{'timestamp'};
	$ag->{'Waits'}++;
	$ag->{'WaitDuration'} += $dur;

	# triggers the popup
	DialerUtils::bridge_agent($dbh, $AgentId, $orig->{'PhoneNumber'});

	# change agent status to 'Connected'
	$ag->{'Status'} = 'Connected';
	$ag->{'AG_BridgedTo'} = $orig->{'PhoneNumber'}; # used in AC cdr
	$ag->{'BridgedTo'} = {
							'OriginationId' => $oaid, # 'PhoneNumber' is used in AC cdr
							'ProspectChanId' => $pchanId,
							'AgentChanId' => $bchanId,
						};
	my $q = $projectQs{$r->{'PJ_Number'}};
	if (defined($q)) {
		$q->{'DialingCount'}-- if ($q->{'DialingCount'} > 0);
	} else {
		$log->warn("bad project number referenced");
	}

	# pause the agent ...
	my $interface = "Agent/$AgentId";
	$ast->send_action('QueuePause', { 'Paused' => 'true', 'Interface' => $interface });

	$log->debug("$desc bridged to prospect " . $orig->{'PhoneNumber'} . 
		" (on $pchanId) agent waited $dur secs and paused on interface $interface");
}

sub realtime_stats() {

	# generates a text file for each project and one for admins
	$log->debug("real time stats - begin");
	my $afile = "/tmp/Admin-CC.html";
	open ADMIN, '>', $afile  or die "failed to open $afile file: $!";
	my ($nowd, $nowt) = DialerUtils::local_datetime();
	print ADMIN "$REALTIME_STATS_HEADER<p>$nowd $nowt</p>";
	my $now = [gettimeofday()];

	for my $pjnum (sort keys %projectQs) {
		my $q = $projectQs{$pjnum};
		
		# holds the project file
		my $pstr = sprintf "<h1>Project %5d %s ", $pjnum, $q->{'PJ_Description'};

		if ($q->{'HaltingReason'} ne '') {
			$pstr .= sprintf("[Halting: %s] ", $q->{'HaltingReason'});
		}

		$pstr .= '- Agents (';
		my $all;
		($q->{'AgentCounts'}, $all) = update_AgentCounts($pjnum);
		for my $astatus (sort keys %{$q->{'AgentCounts'}}) {
			$pstr .= sprintf("%s:%d ", $astatus, $q->{'AgentCounts'}{$astatus});
		}

		my ($hperc, $mperc) = (0,0);
		if ($q->{'CallCount'} > 0) {
			$hperc = int(100 * ($q->{'HumanCount'} / $q->{'CallCount'}));
			$mperc = int(100 * ($q->{'MachineCount'} / $q->{'CallCount'}));
		}
		my $xperc = 100 - $hperc - $mperc;
		my $aperc = 0;
		if ($q->{'HumanCount'} > 0) {
			$aperc = (100 * $q->{'QueueAbandoned'}) / $q->{'HumanCount'};
		}

		my $pjelapsed = DialerUtils::hhmmss(tv_interval($q->{'StartTimestamp'}, $now),0);

		$pstr .= ")</h1>\n<table cellspacing=1>
			<tr><th class=\"basiclist-row\">Time Stamp</th><td class=\"basiclist\">&nbsp;$nowd $nowt (Elapsed: $pjelapsed)&nbsp;</td></tr>
			<tr><th class=\"basiclist-row\">Calls (Total)</th><td class=\"basiclist\">&nbsp;" . sprintf('%d (%d%% live, %d%% machine, %d%% non-connect)', $q->{'CallCount'}, $hperc, $mperc, $xperc) . "&nbsp;</td></tr>
			<tr><th class=\"basiclist-row\">Queue Abandons</th><td class=\"basiclist\">&nbsp;" . 
					sprintf('%d (%0.2f%% of live), %d in the last minute', 
						$q->{'QueueAbandoned'}, $aperc, $q->{'QueueAbandoned'} - $q->{'QAbandonCheckpoint'}) . "&nbsp;</td></tr>
			<tr><th class=\"basiclist-row\">Agent Calls</th><td class=\"basiclist\">&nbsp;" . $q->{'AgConnCount'} . "&nbsp;</td></tr>
			<tr><th class=\"basiclist-row\">Average Agent Call Length</th><td class=\"basiclist\">&nbsp;" . int($q->{'AgAveCallLength'}) . " seconds&nbsp;</td></tr>
			<tr><th class=\"basiclist-row\">Agent Connect Ratio</th><td class=\"basiclist\">&nbsp;" . sprintf('%0.1f%%', 100* $q->{'AgConnRatio'}) . "&nbsp;</td></tr>
			<tr><th class=\"basiclist-row\">Ideal Handling Rate</th><td class=\"basiclist\">&nbsp;" . int($q->{'IdealHandlingRate'}) . " calls/hr&nbsp;</td></tr>
			<tr><th class=\"basiclist-row\">Target Dialing Rate</th><td class=\"basiclist\">&nbsp;" . int($q->{'TargetDialingRate'}) . 
				" calls/hr. "  . sprintf('(Prediction Factor: %0.3f, Call Gap: %0.2f sec)', $q->{'PredictionFactor'}, $q->{'CallGap'}) . " </td></tr>
			";

		$pstr .= "<tr><th class=\"basiclist-row\">Queued</th><td class=\"basiclist\">&nbsp;";
		for my $num (keys %{$q->{'ListQueued'}}) {
			$pstr .= "$num ";
		}
		$pstr .= "&nbsp;</td></tr>\n";

		my $cacheSize = scalar(keys %{$q->{'NumbersCache'}});

		$pstr .= "<tr><th class=\"basiclist-row\" title=\"CacheSize=$cacheSize\">Calling</th><td class=\"basiclist\">&nbsp;";
		my $c = 1;
		for my $num (keys %{$q->{'ListOriginations'}}) {
			$pstr .= "$num ";
			$pstr .= '<br>&nbsp;' if ($c > 0) && ($c % 10 == 0);
			$c++;
		}

		$pstr .= "&nbsp;</td></tr></table><br/>
					<table cellspacing=1><tr>
					<th class=\"basiclist-col\">Agent</th>
					<th class=\"basiclist-col\">Status</th>
					<th class=\"basiclist-col\">Calls Taken</th>
					<th class=\"basiclist-col\">Ave Call Len</th>
					<th class=\"basiclist-col\">Ave Wait</th>
					<th class=\"basiclist-col\">Elapsed</th>
					<th class=\"basiclist-col\">Calls/hr</th>
					</tr>\n";

		for my $anum (keys %agents) {
			my $a = $agents{$anum};
			next unless ($a->{'AG_Project'} == $pjnum);

			$pstr .= "<tr>";

			# Agent
			$pstr .= "<th class=\"basiclist-row\" title=\"AG_Number=$anum\">" . $a->{'AG_Name'} . "</th>";

			# Status
			$pstr .= "<td class=\"basiclist\">" . $a->{'Status'};
			if ((defined($a->{'AG_BridgedTo'})) && (length($a->{'AG_BridgedTo'}) > 1)) {
				$pstr .= " to " . $a->{'AG_BridgedTo'};
			}
			$pstr .= "</td>";

			# Calls
			$pstr .= "<td class=\"basiclist-right\">" . $a->{'Calls'} . "</td>";

			# Ave Call Len
			my $aloc = 0;
			if ($a->{'Calls'} > 0) {
				$aloc = sprintf('%0.1f', $a->{'CallDuration'} / $a->{'Calls'});
			}
			$pstr .= "<td class=\"basiclist-right\">$aloc</td>";

			# Ave Wait
			my $awt = 0;
			if ($a->{'Waits'} > 0) {
				$awt = sprintf('%0.1f', $a->{'WaitDuration'} / $a->{'Waits'});
			}
			$pstr .= "<td class=\"basiclist-right\">$awt</td>";

			# Elapsed time
			my $esecs = tv_interval($a->{'LoginTimestamp'}, $now);
			$pstr .= "<td class=\"basiclist-right\">" . DialerUtils::hhmmss($esecs,0) . "</td>";

			# Calls/hr
			my $crate = 0;
			if ($esecs > 0) {
				$crate = sprintf('%0.1f', 60 * 60 * ($a->{'Calls'} / $esecs));
			}
			$pstr .= "<td class=\"basiclist-right\">$crate</td>";
			
			$pstr .= "</tr>\n";
		}

		# logged off agents
		my $res = $dbh->selectall_arrayref("select AG_Number, AG_Name,
			unix_timestamp(AG_Lst_Change) as LastChangeUnix
			from agent where
			AG_Project = $pjnum and AG_SessionId is null
			and AG_Status = 'A' and AG_MustLogin = 'Y'",
			{ Slice => {}});
		
		for my $a (@$res) {
			$pstr .= "<tr>";

			# Agent
			$pstr .= "<th class=\"basiclist-row\" title=\"AG_Number=" .
				$a->{'AG_Number'} . "\">" . $a->{'AG_Name'} . "</th>";

			# Status
			$pstr .= "<td class=\"basiclist\">Logged Off</td>";

			# Calls, Ave Call Len, Ave Wait
			$pstr .= "<td class=\"basiclist-right\"></td>";
			$pstr .= "<td class=\"basiclist-right\"></td>";
			$pstr .= "<td class=\"basiclist-right\"></td>";

			# Elapsed time
			my $esecs = time() - $a->{'LastChangeUnix'};
			$pstr .= "<td class=\"basiclist-right\">" . DialerUtils::hhmmss($esecs,0) . "</td>";

			# Calls/hr
			$pstr .= "<td class=\"basiclist-right\"></td>";
			
			$pstr .= "</tr>\n";
		}

		$pstr .= "</table>\n";

		my $sname = uc($q->{'PJ_Description'});
		$sname =~ tr/0-9A-Z//cd;
		my $fname = "/tmp/$pjnum-$sname-CC.html";
		open PJFILE, '>', $fname or die "failed to open $fname: $!";
		print PJFILE "$REALTIME_STATS_HEADER$pstr$REALTIME_STATS_FOOTER";
		close PJFILE;
		system("mv $fname $rstatsDir");

		print ADMIN "$pstr<br>\n"; # with a blank line

	}

	print ADMIN $REALTIME_STATS_FOOTER;
	close ADMIN;
	system("mv $afile $rstatsDir");
	system("rsync $rstatsDir/* www-data\@$worker0:/dialer/www/fancy/ &");

	$log->debug("real time stats - end");
}

# +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++ main

$SIG{INT} = \&exit_handler;
$SIG{QUIT} = \&exit_handler;
$SIG{TERM} = \&exit_handler;

$ast->load_AREACODE_STATE();

open(PID, ">", "/var/run/astcoldcaller.pid");
print PID $$;
close(PID);

my %Iterations = (
	'Every 2 Seconds' => 0,
	'Every 6 seconds' => 0,
	'Once a minute' => 0,
	'Every 3 minutes' => 0,
	);

my $nextIter = 0;

$log->debug("Event loop starts");

while ($ast->{'running'} > 0) {
	my $nowt = time();

	# Every 2 Seconds
	if ($Iterations{'Every 2 Seconds'} < $nowt) {
		realtime_stats();
		$Iterations{'Every 2 Seconds'} = $nowt + 2;
	}

	# Every 6 seconds
	if ($Iterations{'Every 6 seconds'} < $nowt) {
		look_for_work();
		numbers_maint($nowt);
		prediction_adjustment();
		$Iterations{'Every 6 seconds'} = $nowt + 6;
	}

	# Once a minute
	if ($Iterations{'Once a minute'} < $nowt) {
		$log->debug("Once a minute");
		$ast->flush_cdrs($worker0);
		$Iterations{'Once a minute'} = $nowt + 60;
	}

	# Every 3 minutes
	if ($Iterations{'Every 3 minutes'} < $nowt) {
		$log->debug("Foreign channel purging - begins");
		$ast->foreign_channels();
		$log->debug("Foreign channel purging - ends");
		$Iterations{'Every 3 minutes'} = $nowt + 180;
	}

	check_message_queue();
	$ast->check_completions(\&timeout_callback, \&result_callback);
	check_completed_transfers();
	originate();

	if ($ast->{'running'} > 0) {
		$ast->handle_events(\&originate,
			{ 
			  'agentlogin' => \&agentlogin_ehandler,
			  'agentlogoff' => \&agentlogoff_ehandler,
			  'join' => \&join_ehandler,
			  'leave' => \&leave_ehandler,
			  'masquerade' => \&masquerade_ehandler,
			  'rename' => \&rename_ehandler,
			  'agentconnect' => \&agentconnect_ehandler,
			  'dial' => \&dial_ehandler,
			  'hangup' => \&hangup_ehandler, # additional to AstManager
			  'varset' => \&varset_ehandler, # additional to AstManager
			  'queuecallerabandon' => \&QueueCallerAbandon_ehandler,
			});
	}

	if ($ast->{'running'} == 2) {
		$ast->{'running'} = 1;
		$ast->{'running'} = 0; # TODO
	}
}

# halt all projects
for my $pjnum (sort keys %projectQs) {
	my $q = $projectQs{$pjnum};

	pjq_halting($q, 'Shutdown');
}

$ast->flush_cdrs($worker0);

$dbh->disconnect;
$ast->disconnect;

# statistics();
$log->debug("Terminating");
$log->fin;

exit;
