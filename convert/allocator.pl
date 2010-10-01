#!/usr/bin/perl

use strict;
use warnings;

use lib '/dialer/www/perl';
use DateTime;
use Carp;
use DialerUtils;
use Time::HiRes qw( gettimeofday tv_interval );

my $t0 = [gettimeofday()];

DialerUtils::daemonize();
open(PID, ">", "/var/run/allocator.pid");
print PID $$;
close(PID);
print("\n\nstarts with pid $$\n");
warn("\nstarts with pid $$");

my $me = DialerUtils::who_am_I();

my $dbh;
my @runnables;
my @warns;
my %TIMEZONES = (
	'0'		=> 'America/New_York',
	'-1'	=> 'America/Chicago',
	'-2'	=> 'America/Denver',
	'-3'	=> 'America/Los_Angeles',
	'-4'	=> 'America/Anchorage',
	'-5'	=> 'Pacific/Honolulu',
	'-6'	=> 'Pacific/Kiritimati',
	'-7'	=> 'Pacific/Auckland',
	'-8'	=> 'Pacific/Wake',
	'-9'	=> 'Australia/Sydney',
	'-10'	=> 'Asia/Tokyo',
	'-11'	=> 'Asia/Hong_Kong',
	'-12'	=> 'Asia/Bangkok',
	'-13'	=> 'Asia/Novosibirsk',
	'-14'	=> 'Asia/Yekaterinburg',
	'-15'	=> 'Asia/Tbilisi',
	'-16'	=> 'Europe/Moscow',
	'-17'	=> 'Asia/Jerusalem',
	'-18'	=> 'Europe/Paris',
	'-19'	=> 'Europe/London',
	'-20'	=> 'Atlantic/Azores',
	'-21'	=> 'Atlantic/South_Georgia',
	'-22'	=> 'America/Argentina/Buenos_Aires',
	'-23'	=> 'America/Halifax'
);
my @plans;
my $tot_demand;
my $tot_capacity;
my $tot_actual;
my %CarrierCapacityLeft;

my $LINES_PER_DOLLAR = 20;


# .............................................................................
sub logmsg {

	my ($dt, $tm) = DialerUtils::local_datetime();

	my $t1 = [gettimeofday()];
	my $elapsed = tv_interval($t0, $t1);
	my $m = sprintf('%0.3f', $elapsed);
	$t0  = $t1;

	print "$dt $tm ($m):";
	print @_;
	print "\n";
}

# .............................................................................
sub cleanup {

	# lines in 'S' status for longer than than 50 minutes 
	# automatically become error 
	 $dbh->do("update line set ln_action = 0,
		 		ln_reson = 'Stuck line bug',
				ln_status = 'E',
				ln_info = '',
				ln_PJ_Number=0,
				ln_AG_Number=0,
				ln_lastused=CURRENT_TIMESTAMP() 
				where ln_lastused < date_sub(now(), interval 50 minute) 
					and ln_status = 'S'");

	# blocked projects get the proper PJ_timeleft message
	$dbh->do("update project set PJ_timeleft = 'Blocked'
				where PJ_Status = 'B' and PJ_timeleft != 'Blocked'");

	# old projects get the proper PJ_timeleft message
	$dbh->do("update project set PJ_timeleft = 'Stopped already'
				where PJ_Status != 'B' and PJ_timeleft != 'Stopped already'
				and PJ_DateStop < current_date()");
	
}

# .............................................................................
sub leads_situation {
	my $pj     = shift; # project, customer, reseller record
	my $pjdesc = shift; # description for logs

	$pj->{'X_LeadsLeft_TZ'} = 0; 
	$pj->{'X_TimeZones_ARRAYREF'} = DialerUtils::timezones_allowed(
		$pj->{'PJ_Local_Time_Start'}, $pj->{'PJ_Local_Start_Min'},
		$pj->{'PJ_Local_Time_Stop'}, $pj->{'PJ_Local_Stop_Min'});

	# check that $tbl exists 
	my $tbl = 'projectnumbers_' . $pj->{'PJ_Number'};
	my $res = $dbh->selectrow_hashref("show table status 
		where name = '$tbl'");

	if ((! defined($res)) || (! defined($res->{'Name'}))) {
		# $tbl does not exist
		# X_LeadsLeft_TZ is already 0
		logmsg("$pjdesc has no $tbl table. So 0 leads in allowed time zones: ", map({ " $_" } @{$pj->{'X_TimeZones_ARRAYREF'}}));
		return;
	}
	
	my $zone_predicate = '(';
	my $sep = '';
	for my $tz (@{$pj->{'X_TimeZones_ARRAYREF'}}) {
		$zone_predicate .= "$sep PN_Timezone = $tz";
		$sep = " or";
	}
	$zone_predicate .= ')';
	if ($zone_predicate eq '()') {
		# X_LeadsLeft_TZ is already 0
		logmsg("$pjdesc not active in any timezones");
		return;
	}

	my $ssz = $pj->{'PJ_Maxline'} * 5 * 3; # sample size
	$ssz = 90000 if $ssz > 90000;
	$res = $dbh->selectall_arrayref("select PN_BestCarriers 
		from $tbl where PN_Status != 'X' and
		$zone_predicate order by PN_Seq limit $ssz",
		{ Slice => {}});

	my %plans;
	for my $row (@$res) {
		$plans{$row->{'PN_BestCarriers'}}++;
		$pj->{'X_LeadsLeft_TZ'}++;
	}
	$pj->{'X_Route_Plans_HASHREF'} = \%plans;

	logmsg("$pjdesc has at least " . $pj->{'X_LeadsLeft_TZ'} . ' leads in allowed time zones: ',  map({ " $_" } @{$pj->{'X_TimeZones_ARRAYREF'}}));
}

# .............................................................................
sub set_pj_time {
	my ($pDate, $pHour, $pMin, $pTZ) = @_;

	croak("Undefined date") unless ($pDate);

	my ($year, $month, $day);
	if ($pDate =~ /(\d{4})-(\d*)-(\d*)/) {
		($year, $month, $day) = ($1, $2, $3);
	} else {
		carp("Date ($pDate) is wrong format - using 2007-01-01 instead");
		($year, $month, $day) = (2007, 1, 1);
	}

	$year = 2007 if ($year == 0);
	$month = 1 if (($month <= 0) || ($month > 12));
	$day =1 if (($day <= 0) || ($day > 31));

	if ($pHour > 23) {
		$pHour = 23; 
		$pMin = 59;
	}

	my $ret_dt;
	eval {
		$ret_dt = DateTime->new(
			year   => $year,
			month  => $month,
			day    => $day,
			hour   => $pHour,
			minute => $pMin,
			second => 0,
			nanosecond => 0,
			time_zone => $TIMEZONES{$pTZ}
		);
	};
	if ($@) {
		print "pDate=$pDate, pHour=$pHour, pMin=$pMin, pTZ=$pTZ\n";
		die $@;
	}
	return $ret_dt;
}

# .............................................................................
sub build_runnable_projects {

	@runnables = ();

	# when is now
	my $now = DateTime->now;
	$now->set_time_zone('America/New_York');
	logmsg('=====> Current eastern time: ' .
		$now->ymd . ' ' . $now->hms);

	# get a rough list of projects to start with, we cannot be any more refined
	# since the stored PJ_DateStop is local not Eastern.
	my $projects = $dbh->selectall_arrayref(q|
		select *, (select count(*) from agent where ag_project = PJ_Number 
					and ag_status = 'A' and
						( (AG_MustLogin = 'N') or
						  (AG_MustLogin = 'Y' and length(AG_SessionId) > 5)
						)) as X_AgentsAvailable
		from project
		left join customer on PJ_CustNumber = CO_Number
		left join reseller on CO_ResNumber = RS_Number
		where 
			PJ_Status = 'A' and
			(PJ_DateStop >= date_sub(current_date(), interval 1 day) or PJ_DateStop is null) and
			PJ_Visible = 1
			and (RS_OnlyColdCall = 'N' or CO_OnlyColdCall = 'N' or PJ_Type = 'C')
		order by rand()
	|,  { Slice => {} });

	PROJECT: for my $pj (@$projects) {
		my $pjdesc = 'Project ' . $pj->{'PJ_Number'} . ': {' . $pj->{'PJ_Description'} . 
			'} for customer ' . $pj->{'CO_Number'} . '-' . $pj->{'CO_Name'};

		# determine X_Calls
		my $row = $dbh->selectrow_hashref("select RE_Calls, RE_Answered from report 
			where re_date = current_date() and 
			RE_Agent = 9999 and RE_Project = " . $pj->{'PJ_Number'});
		if (defined($row->{'RE_Calls'})) {
			$pj->{'X_Calls'} = $row->{'RE_Calls'};
			$pj->{'X_Answered'} = $row->{'RE_Answered'};
		} else {
			$pj->{'X_Calls'} = 0;
			$pj->{'X_Answered'} = 0;
		}

		# for weekend check
		my $nowlocal = DateTime->now;
		$nowlocal->set_time_zone($TIMEZONES{$pj->{'CO_Timezone'}});
		my $localdow = $nowlocal->day_of_week; # 1 being Monday and 7 being Sunday

		# start and stop
		my $startdt = set_pj_time($pj->{'PJ_DateStart'},
			$pj->{'PJ_TimeStart'}, $pj->{'PJ_TimeStartMin'}, 
			$pj->{'CO_Timezone'});
		my $stopdt;
		if ($pj->{'PJ_DateStop'}) {
			$stopdt = set_pj_time($pj->{'PJ_DateStop'},
				$pj->{'PJ_TimeStop'}, $pj->{'PJ_TimeStopMin'}, 
				$pj->{'CO_Timezone'});
		} else {
			$stopdt = DateTime->new(
				year => 2100, month => 12, day => 1,
				hour => 12, minute => 0, second => 0);
		}

		# callcenter dt 
		my $workday_startdt = set_pj_time($nowlocal->ymd,
			$pj->{'PJ_TimeStart'}, $pj->{'PJ_TimeStartMin'}, 
			$pj->{'CO_Timezone'});
		my $workday_stopdt = set_pj_time($nowlocal->ymd,
				$pj->{'PJ_TimeStop'}, $pj->{'PJ_TimeStopMin'}, 
				$pj->{'CO_Timezone'});

		my $runmsg;

		if ($pj->{'RS_Status'} ne 'A') {
			$runmsg = 'Inactive reseller';
		} elsif ($pj->{'RS_Credit'} < 1) {
			$runmsg = 'No reseller credit';
		} elsif ($pj->{'RS_Maxlines'} < 1) {
			$runmsg = 'No reseller lines';
		} elsif ($pj->{'CO_Status'} ne 'A') {
			$runmsg = 'Inactive customer';
		} elsif ($pj->{'CO_Maxlines'} < 1) {
			$runmsg = 'No customer lines';
		} elsif ($pj->{'PJ_Maxline'} < 1) {
			$runmsg = 'No project lines';
		} elsif ($pj->{'CO_Credit'} < 0.01) {
			$runmsg = 'No customer credit';
		} elsif (($pj->{'PJ_Maxday'} > 0) && 
			($pj->{'X_Calls'} >= $pj->{'PJ_Maxday'})) {
			$runmsg = 'Daily maximum';
		} elsif (DateTime::compare($startdt,$now) >= 0) { # starts later
			$runmsg = 'Start in future';
		} elsif (DateTime::compare($stopdt,$now) < 0) { # stopped already
			$runmsg = 'Stopped already';
		} elsif (DateTime::compare($workday_startdt,$nowlocal) >= 0) { 
			$runmsg = 'Workday not started';
		} elsif (DateTime::compare($workday_stopdt,$nowlocal) < 0) { 
			$runmsg = 'Workday has ended';
		} elsif (($localdow == 6) && # Saturday
			($pj->{'PJ_Weekend'} != 1) && ($pj->{'PJ_Weekend'} != 3)) { 
			$runmsg = 'Not on Saturday';
		} elsif (($localdow == 7) && # Sunday
			($pj->{'PJ_Weekend'} != 2) && ($pj->{'PJ_Weekend'} != 3)) { 
			$runmsg = 'Not on Sunday';
		}

		unless ($runmsg) {
			leads_situation($pj, $pjdesc);

			if ($pj->{'X_LeadsLeft_TZ'} == 0) { 
				$runmsg = 'No leads in timezone';
			}
		}

		if ((! $runmsg) && ($pj->{'X_AgentsAvailable'} == 0)) {
			if (($pj->{'PJ_Type'} eq 'P') &&
				 ((! defined($pj->{'PJ_PhoneCallC'})) || ($pj->{'PJ_PhoneCallC'} eq ""))) {
				$runmsg = 'No agents ready';
			} elsif ($pj->{'PJ_Type'} eq 'C') {
				$runmsg = 'No agents ready';
			}
		}

		# skip || runnable
		unless ($runmsg) {

			if ($pj->{'PJ_Type'} eq 'C') {
				$runmsg = "Running*";
			} else {
				$runmsg = "Running";

				# not Asterisk Cold Calling
				$pj->{'X_CurrentLines'} = 0;
				$pj->{'X_CarrierAllocatedTotal'} = 0; 

				if ((! defined($pj->{'PJ_OrigPhoneNr'})) ||
					($pj->{'PJ_OrigPhoneNr'} eq '')) {
					# fetch a reseller default CID
					my $rcid = $dbh->selectrow_hashref("select RC_CallerId from
						rescallerid where RC_Reseller = " . $pj->{'RS_Number'} . 
						" and RC_DefaultFlag = 'Y' order by rand() limit 1");

					if (defined($rcid->{'RC_CallerId'})) {
						$pj->{'PJ_OrigPhoneNr'} = $rcid->{'RC_CallerId'};
						logmsg('Reseller ' . $pj->{'RS_Number'} . ' default CID ' . $rcid->{'RC_CallerId'} . 
							" used for $pjdesc");
					}
				}

				push(@runnables, $pj);
			}
		}
		$dbh->do("update project set PJ_timeleft = '$runmsg' where PJ_Number = "
			. $pj->{'PJ_Number'}) or carp($!);
	}
}

# .............................................................................
sub adjust_demand_for_leads_left {

	for my $pj (@runnables) {
		my $left = $pj->{'X_LeadsLeft_TZ'};

		# calculate initial demand
		my $initial_demand = $pj->{'PJ_Maxline'};

		# adjust it for leads left
		if ($initial_demand > ($left / 5)) {
			$pj->{'X_Demand_1'} = int($left / 5) + 1;
			logmsg("Project " . $pj->{'PJ_Number'} . " had its demand reduced "
				. "from $initial_demand to " . $pj->{'X_Demand_1'} .
				" lines, because leads-left = $left") 
		} else {
			$pj->{'X_Demand_1'} = $initial_demand;
		}
	}
}

# .............................................................................
sub check_customer_maxlines {

	my %customers = ();

	for my $pj (@runnables) {
		$customers{$pj->{'CO_Number'}}{'CO_Maxlines'} = $pj->{'CO_Maxlines'};
		$customers{$pj->{'CO_Number'}}{'CO_Name'} = $pj->{'CO_Name'};
		$customers{$pj->{'CO_Number'}}{'CO_Credit'} = $pj->{'CO_Credit'};
		$customers{$pj->{'CO_Number'}}{'CO_ResNumber'} = $pj->{'CO_ResNumber'};
		$customers{$pj->{'CO_Number'}}{'X_Demand_1'} += $pj->{'X_Demand_1'};
	}

	for my $c (keys %customers) {
		my $adj = 1;

		my $lines = $customers{$c}{'CO_Maxlines'};
		if (($LINES_PER_DOLLAR * $customers{$c}{'CO_Credit'}) < $customers{$c}{'CO_Maxlines'}) {
			logmsg("Customer $c-" . $customers{$c}{'CO_Name'} . 
				' has $' . $customers{$c}{'CO_Credit'} . 
				' left, reducing max lines');
			# the "+ 1" below is to prevent lines being set to zero
			$lines = int($customers{$c}{'CO_Credit'} * $LINES_PER_DOLLAR) + 1;

		}

		if ($customers{$c}{'X_Demand_1'} > $lines) {
			$adj = $lines / $customers{$c}{'X_Demand_1'};
			logmsg("Customer $c-" . $customers{$c}{'CO_Name'} . 
				' has sum(X_Demand_1) = ' . $customers{$c}{'X_Demand_1'} .
				" lines BUT lines allowed = $lines --> factor="
				. sprintf('%0.3f', $adj));

			if ($customers{$c}{'CO_ResNumber'} == 1) {
				push(@warns, 
					"Customer $c-" . $customers{$c}{'CO_Name'} .
					' would like ' . $customers{$c}{'X_Demand_1'} .
					" lines, but is only getting $lines lines.");
			}
		}

		if (($customers{$c}{'CO_ResNumber'} == 1) &&
			($customers{$c}{'X_Demand_1'} > (5 * $customers{$c}{'CO_Credit'})) &&
			($customers{$c}{'CO_Credit'} < 50)) {
			push(@warns, 
				"Customer $c-" . $customers{$c}{'CO_Name'} .
				' may need to add money, credit=' . 
				sprintf('%0.2f', $customers{$c}{'CO_Credit'}) . 
				', wants ' . $customers{$c}{'X_Demand_1'} .
				' lines.');
		}

		# calculate X_Demand_2 ===> demand after customer max
		for my $pj (@runnables) {
			next if $pj->{'CO_Number'} != $c;
			$pj->{'X_Demand_2'} = int($pj->{'X_Demand_1'} * $adj);
		}
	}
}

# .............................................................................
sub check_reseller_maxlines {

	my %resellers = ();

	for my $pj (@runnables) {
		$resellers{$pj->{'RS_Number'}}{'RS_Maxlines'} = $pj->{'RS_Maxlines'};
		$resellers{$pj->{'RS_Number'}}{'RS_Name'} = $pj->{'RS_Name'};
		$resellers{$pj->{'RS_Number'}}{'RS_Credit'} = $pj->{'RS_Credit'};
		$resellers{$pj->{'RS_Number'}}{'X_Demand_2'} += $pj->{'X_Demand_2'};
	}

	for my $r (keys %resellers) {
		my $adj = 1;

		if ($r > 1) { # real resellers only
			# the "+ 1" below is to prevent lines being set to zero
			my $lines = $LINES_PER_DOLLAR * $resellers{$r}{'RS_Credit'} + 1;
			if ($resellers{$r}{'RS_Maxlines'} < $lines) {
				$lines = int($resellers{$r}{'RS_Maxlines'});
			}

			if ($resellers{$r}{'RS_Credit'} < 50) {
				push(@warns, 
					"Reseller $r-" . $resellers{$r}{'RS_Name'} . 
					' may need to add money, credit=' . 
					sprintf('%0.2f', $resellers{$r}{'RS_Credit'}) . 
					', wants ' . $resellers{$r}{'X_Demand_2'} .
					' lines.');
			}

			if ($resellers{$r}{'X_Demand_2'} > $lines) {
				$adj = $lines / $resellers{$r}{'X_Demand_2'};
				logmsg("Reseller $r-" . $resellers{$r}{'RS_Name'} . 
					' has sum(X_Demand_2) = ' . $resellers{$r}{'X_Demand_2'} .
					' lines BUT allowed lines = ' . $lines . 
					' --> factor=' . sprintf('%0.3f', $adj));
			}
		}

		# calculate X_Demand_3 ===> demand after reseller max
		for my $pj (@runnables) {
			next if $pj->{'RS_Number'} != $r;
			$pj->{'X_Demand_3'} = int($pj->{'X_Demand_2'} * $adj);
		}
	}
}

# .............................................................................
sub adjust_for_overall_capacity {

	my $capacity_factor = 0.99; # never exceed 99% of capacity

	# determine initial demand
	$tot_demand = 0;
	for my $pj (@runnables) {
		$tot_demand += $pj->{'X_Demand_3'};
		$pj->{'X_Demand_4'} = $pj->{'X_Demand_3'};
	}
	logmsg("Total demand before considering capacity = $tot_demand");

	# determine capacity
	my $q = $dbh->selectrow_hashref('select count(*) as Total from line, switch ' .
		"where (ln_status = 'F' or ln_status = 'U' or ln_status = 'W' or ln_status = 'S')" . 
		" and ln_switch = sw_id");
	$tot_capacity = $q->{'Total'};
	logmsg("Available lines = $tot_capacity");

	# keep decreasing lines from projects, bigger amounts for lower
	# priority projects with some protection for small projects.
	my $untouchable = 100;
	my $gap = $tot_demand - ($tot_capacity * $capacity_factor);
	while (($gap > 0) && ($untouchable >= 0)) {
		my $oldgap = $gap;
		for my $pj (@runnables) {
			if ($pj->{'X_Demand_4'} > $untouchable) {
				my $delta = int($pj->{'X_Demand_4'} * ($pj->{'RS_Priority'} + $pj->{'CO_Priority'}) / 1000);
				$delta = 1 if ($delta > $pj->{'X_Demand_4'}) || ($delta == 0);

				$pj->{'X_Demand_4'} -= $delta;
				$gap -= $delta;
			}
		}
		$untouchable-- if $oldgap == $gap;
	}
}

# .............................................................................
sub get_runnable {
	my $searchval = shift;

	for my $pj (@runnables) {
		if ($pj->{'PJ_Number'} == $searchval) {
			return $pj;
		}
	}

	return undef;
}

# .............................................................................
sub stop_project {
	my $pjid = shift;

	$dbh->do("update line set ln_action = 999999
		where ln_PJ_Number = $pjid and ln_status != 'S'");

	$dbh->do("update project set PJ_timeleft = 'Not running'
				where PJ_Number = $pjid") or carp($!);
}

# .............................................................................
sub stop_nonrunnables {
	# stop the projects that are no longer runnable and calculate 
	# current lines used
	
	$tot_actual = 0;
	my $curs = $dbh->selectall_arrayref("select ln_pj_number, ln_trunk, count(*) as Total 
		from line where ln_pj_number > 0 and substr(ln_info,1,8) != 'DIALLIVE'
		group by ln_pj_number, ln_trunk", { Slice => {} });

	for my $cur (@$curs) {
		my $rp = get_runnable($cur->{'ln_pj_number'});
		$tot_actual += $cur->{'Total'};

		if (defined($rp)) {
			$rp->{'X_CurrentLines'} += $cur->{'Total'};
			$rp->{'X_CarrierOld' . $cur->{'ln_trunk'}} = $cur->{'Total'};
		} else {
			logmsg('Project ' . $cur->{'ln_pj_number'} . 
				' is no longer runnable. Stopping on ' .
				$cur->{'Total'} . ' lines on carrier ' .
				$cur->{'ln_trunk'});
			stop_project($cur->{'ln_pj_number'});
		}
	}	
}

# .............................................................................
sub assign_lines {
	# note: nonrunnables that were stopped will not liberate their lines just yet.
	
	# adjust lines from smaller projects to larger projects
	for my $pj (sort { $a->{'X_CurrentLines'} <=> $b->{'X_CurrentLines'} } @runnables) {
		for my $k (keys %CarrierCapacityLeft) {
			my $limit = $pj->{"X_CarrierOld$k"} - $pj->{"X_Carrier$k"};

			if ($limit > 0) {
				my $aff = $dbh->do("update line 
					set ln_action = 999999
					where ln_action = 0 and ln_trunk = '$k' and
					ln_PJ_Number = " . $pj->{'PJ_Number'} . "
					order by ln_priority DESC, ln_channel DESC 
					limit $limit");
				
				logmsg('Project ' . $pj->{'PJ_Number'} . 
					' line count decreased from ' . $pj->{"X_CarrierOld$k"} .
					' to ' . $pj->{"X_Carrier$k"} . " on carrier $k  (updated $aff lines)");
			} elsif ($limit < 0) { # $limit == 0 is boring
				$limit = $pj->{"X_Carrier$k"} - $pj->{"X_CarrierOld$k"};


				my $cc = ($pj->{'PJ_PhoneCallC'}) ? $pj->{'PJ_PhoneCallC'} : "";
				my $cid = ($pj->{'PJ_OrigPhoneNr'}) ? $pj->{'PJ_OrigPhoneNr'} : ""; 
				my $aff = $dbh->do("update line set
					ln_lastused = now(),
					ln_action = " . $pj->{'PJ_Number'} . ", 	
					ln_info ='" . 
						$pj->{'PJ_Type'} . ';' .
						$pj->{'PJ_Type2'} . ';' .
						"$cc;$cid' 
					where ln_status = 'F' and ln_trunk = '$k' 
						and ln_action = 0 and 
						ln_action = 0 
					order by ln_lastused, ln_channel
					limit $limit");

				logmsg('Project ' . $pj->{'PJ_Number'} . 
					' will have line count increased from ' . $pj->{"X_CarrierOld$k"} .
					' to ' . $pj->{"X_Carrier$k"} . " on carrier $k  (updated $aff lines)");
			}
		}
	}
}

# .............................................................................
sub check_runnable_warnings {

	# --- check for good P1 response rate, abandon rate etc.
	for my $pj (@runnables) {

		if ($pj->{'PJ_Type'} eq 'P') {
			my $row = $dbh->selectrow_hashref("select sum(RE_Calls) as AgentCalls, sum(RE_Agentnoanswer) as AgentNoAnswer, sum(RE_Agentbusy) as AgentBusy from report where re_date = current_date() and re_agent != 9999 and RE_Project = " . $pj->{'PJ_Number'});
		
			if (!defined($row->{'AgentCalls'})) {
				$pj->{'X_AgentCalls'} = 0;
				$pj->{'X_AgentResponse'} = 0;
				$pj->{'X_AgentNoAnswer'} = 0;
				$pj->{'X_AgentBusy'} = 0;
				$pj->{'X_AgentAbandon'} = 0;
			} else {
				$pj->{'X_AgentCalls'} = $row->{'AgentCalls'};
				$pj->{'X_AgentNoAnswer'} = $row->{'AgentNoAnswer'};
				$pj->{'X_AgentBusy'} = $row->{'AgentBusy'};
				if ($pj->{'X_Calls'} > 0) {
					$pj->{'X_AgentResponse'} = $row->{'AgentCalls'} / $pj->{'X_Calls'};
				} else {
					$pj->{'X_AgentResponse'} = 0;
				}
				if ($row->{'AgentCalls'} > 0) {
					$pj->{'X_AgentAbandon'} = ($pj->{'X_AgentNoAnswer'} + $pj->{'X_AgentBusy'}) / $row->{'AgentCalls'};
				} else {
					$pj->{'X_AgentAbandon'} = 0;
				}
			}
		} else {
			$pj->{'X_AgentCalls'} = 'N/A';
			$pj->{'X_AgentNoAnswer'} = 0;
			$pj->{'X_AgentBusy'} = 0;
			$pj->{'X_AgentResponse'} = 'N/A';
			$pj->{'X_AgentAbandon'} = 'N/A';
		}

	}
}

# .............................................................................
sub graphing {

	my $dt = DateTime->now();
	$dt->set_time_zone('America/New_York');
	my $x = $dt->hour + ($dt->minute / 60);
	return if ($x < 8.5);

	if (! -d '/dialer/www/fancy') {
		mkdir '/dialer/www/fancy';
	}

	my $jnow = time() * 1000;
	open(AGDAT, '>>', "/dialer/www/fancy/allocator.graph.json");
	print AGDAT "[ $jnow, $tot_demand, $tot_capacity, $tot_actual ],\n";
	close(AGDAT);

}

# .............................................................................
sub normalize_route_plans {

	# convert the number counts into integer line counts

	for my $pj (@runnables) {
		next if  $pj->{'X_Demand_4'} == 0;

		my %plans = %{$pj->{'X_Route_Plans_HASHREF'}};
		my $total = $pj->{'X_LeadsLeft_TZ'};

		my %pc; # plan line counts
		if ($total > 0) {
			my $itot = 0; # itegral total
			for my $k (keys %plans) {
				$pc{$k} = int($pj->{'X_Demand_4'} * $plans{$k} / $total);
				$itot += $pc{$k};
			}

			my $rem = $pj->{'X_Demand_4'} - $itot;
			SCALINE: while ($rem > 0) {
				for my $k (sort { $plans{$b} <=> $plans{$a} } keys %plans) {
					$pc{$k}++;
					$rem--;
					last SCALINE if $rem <= 0;
				}
			}
		} else {
			logmsg("FATAL: Project " . $pj->{'Pj_Number'} .
				" [" . $pj->{'PJ_Description'} . 
				"] was runnable but had no leads in TZ!");
		}

		my $pstr = '';
		for my $p (keys %pc) {
			$pstr .= " $p=>" . $pc{$p};
		}
		logmsg("Project " . $pj->{'PJ_Number'} .
				" [" . $pj->{'PJ_Description'} . 
				"] has normalized plans:$pstr");
		
		$pj->{'X_Route_Plans_HASHREF'} = \%pc;
	}
}

# .............................................................................
sub combination_array {
	my $lref = shift;

	# first sort them
	my @CARRS = sort @$lref;

	my $sz = scalar(@CARRS);
	my $combos = 2**$sz;
	my @unsorted;
	my $fmt = "\%0$sz" . 'b'; 

	for (my $n = 1; $n <= $combos - 1; $n++) {
		my $p = '';
		my $bp = sprintf($fmt, $n);
		for (my $i = 0; $i < $sz; $i++) {
			if (substr($bp,$i,1) eq '1') {
				$p .= $CARRS[$i];
			}
		}
		push @unsorted, $p
	}

	return \@unsorted;
}

# .............................................................................
sub set_plans {

	# build the sorted list of plans from carriers that have capacity
	my @CARRS;
	for my $k (keys %CarrierCapacityLeft) {
		if ($CarrierCapacityLeft{$k} > 0) {
			push @CARRS, $k;
		}
	}

	my $cref = combination_array(\@CARRS);

	@plans = sort { length($a) <=> length($b) } @{$cref};

}

# .............................................................................
sub determine_carrier_capacity {

	my $q = $dbh->selectall_arrayref(
		"select count(*) as Total, ln_trunk from line
		where (ln_status = 'F' or ln_status = 'U' or ln_status = 'W' or ln_status = 'S')
		group by ln_trunk", { Slice => {}});

	for my $row (@$q) {
		my $carrier = $row->{'ln_trunk'};
		if ($carrier !~ /^[ABCDEFGHI]$/) {
			logmsg("ERROR: unexpected carrier [$carrier] in line table");
		} else {
			$CarrierCapacityLeft{$carrier} = $row->{'Total'};
			logmsg("Carrier $carrier capacity = " . $row->{'Total'});
		}
	}

	# initialize the carrier allocations X_CarrierA etc.
	for my $k (keys %CarrierCapacityLeft) {
		if ($CarrierCapacityLeft{$k} > 0) {
			for my $pj (@runnables) {
				$pj->{"X_Carrier$k"} = 0; 

				# X_CarrierOld may have already been set in stop_nonrunnables
				$pj->{"X_CarrierOld$k"} = 0 unless defined($pj->{"X_CarrierOld$k"}); 
			}
		}
	}
}

# .............................................................................
sub find_best_alternate {
	# finds a suitable alternate plan
	my $pcode = shift;

	# build the sorted list of alternates
	my @CARRS;
	for (my $k = 0; $k < length($pcode); $k++) {
		push @CARRS, substr($pcode,$k,1);
	}

	my $cref = combination_array(\@CARRS);
	# sort: longest first 
	my @alts = sort { length($b) <=> length($a) } @{$cref};

	for my $a (@alts) {
		if (grep(/^$a$/, @plans) > 0) {
			return $a;
		}
	}

	return undef; 
}

# .............................................................................
sub distribute_to_carriers {
	
	# %CarrierCapacityLeft : initially contains the carriers capacity and
	# gets reduced as lines are dedicated to that carrier.
	
	ITERATUM: while (1) { # (needed because we do only 1 line at a time)

		# @plans : contains the list of remaining usable plans, it shrinks as
		# carriers become full
		# @plans must be sorted from most restrictive to least restrictive
		set_plans();
		if (scalar(@plans) == 0) {
			logmsg("All carriers are full.");
			last;
		}

		# clean up after carriers possibly have been exhausted
		# for example: if a project has 
			# $pj->{'X_Route_Plans_HASHREF'}->{'ABC'} == 10 and
			# carrier B has no capacity left then we must set
			# $pj->{'X_Route_Plans_HASHREF'}->{'AC'} += 10
		for my $pj (@runnables) {
			next if $pj->{'X_Demand_4'} == 0;
			my $lost = 0;

			for my $k (keys %{$pj->{'X_Route_Plans_HASHREF'}}) {
				if ($pj->{'X_Route_Plans_HASHREF'}->{$k} == 0) {
					delete $pj->{'X_Route_Plans_HASHREF'}->{$k};
				} elsif (grep(/^$k$/, @plans) == 0) {
					# move lines to the best alternate plan
					my $alt = find_best_alternate($k);
					if (defined($alt)) {
						$pj->{'X_Route_Plans_HASHREF'}->{$alt} +=
							$pj->{'X_Route_Plans_HASHREF'}->{$k};
					} else {
						# use GBLX/QWEST no matter what
						my $lcnt = $pj->{'X_Route_Plans_HASHREF'}->{$k};
						$lost += $lcnt;

						my $g = int($lcnt / 2);
						$pj->{'X_Route_Plans_HASHREF'}->{'F'} += $g;
						$pj->{'X_Route_Plans_HASHREF'}->{'A'} += ($lcnt - $g);
					}
					delete $pj->{'X_Route_Plans_HASHREF'}->{$k};
				}
			}

			if ($lost > 0) {
				# Note: when a carrier becomes full, this may prevent a project from
				# getting its full allocation, since it may need dedicated lines that
				# are not available.
				logmsg("Project " . $pj->{'PJ_Number'} . "-" .
					$pj->{'PJ_Description'} . 
					": had $lost lines unable to follow the plan, because dedicated carrier capacity not available");
			}
		}
		
		# since we clean up, this is a good way to determine if there is more to do
		my $more_to_do = 0;
		for my $pj (@runnables) {
			next if $pj->{'X_Demand_4'} == 0;
			if (scalar(keys %{$pj->{'X_Route_Plans_HASHREF'}}) > 0) {
				$more_to_do = 1;
				last;
			}
		}
		last if $more_to_do == 0;

		my $pCodeLen = 0;
		my $did_something = 0;
		for my $pcode (@plans) { 
			if (($pCodeLen > 0) && ($pCodeLen < length($pcode))
					&& ($did_something == 1)) {
				# we want to exhaust the most restrictive plans before moving 
				# to less restrictive ones
				next ITERATUM;
			}
			$pCodeLen = length($pcode);

			for (my $ci = 0; $ci < $pCodeLen; $ci++) { 
				# for each $carr contained in $pcode that has capacity
				my $carr = substr($pcode,$ci,1);
				next if $CarrierCapacityLeft{$carr} == 0; # saves a sort

				for my $pj (sort { $a->{'X_LeadsLeft_TZ'} <=> $b->{'X_LeadsLeft_TZ'} } @runnables) {
					next if $pj->{'X_Demand_4'} == 0;
					next if $pj->{'X_CarrierAllocatedTotal'} >= $pj->{'X_Demand_4'};
					next unless defined($pj->{'X_Route_Plans_HASHREF'}->{$pcode});

					# for each runnable project sorted by least leads first - since
					# those with least leads probably have the least flexibility when
					# it comes to plan choice

					if ($pj->{'X_Route_Plans_HASHREF'}->{$pcode} > 0) {
						# move the line from the plan to the actual
						$pj->{'X_Route_Plans_HASHREF'}->{$pcode}--;
						$pj->{"X_Carrier$carr"}++;
						$pj->{'X_CarrierAllocatedTotal'}++;
						$CarrierCapacityLeft{$carr}--;
						$did_something = 1;
						if ($CarrierCapacityLeft{$carr} <= 0) {
							next ITERATUM; # so that we can cleanup and start again
						}
					}
				}
			}
		}
	}

	# log the decision
	my $nhfile = '/root/number-helper.input';
	open(NH, '>', "$nhfile.tmp") || die "cannot open $nhfile.tmp: $!";

	for my $pj (@runnables) {
		my $pjnum =  $pj->{'PJ_Number'};
		my $msg = "Project $pjnum carrier distribution:";
		for my $k (keys %CarrierCapacityLeft) {
			my $dist = $pj->{"X_Carrier$k"};
			$msg .= " $k=>$dist"; 
			print NH "$pjnum:$k:$dist\n"; 
		}
		logmsg($msg);
	}
	close(NH);
	link("$nhfile.tmp", $nhfile);
	unlink("$nhfile.tmp");
}

# .............................................................................
sub build_stats_page {

	my @rheads = ('Id', 'Description', 'Customer', 'Reseller', 'Old', 'MaxLines', 'Lead Dmd', 
		'CMax Dmd', 'RMax Dmd', 'Cpy Dmd', 
		map({ "Carr-$_" } sort keys %CarrierCapacityLeft),
		map({ "Old-$_" } sort keys %CarrierCapacityLeft),
		'Type', 'P-Calls', 'A-Calls', 'AN+AB', 'Resp', 'Aband', 'ASR');
	my $runs = "";
	my $noruns = "";
	my $cc = "";
	my %rtotal;
	$rtotal{'X_CurrentLines'} = 0;
	$rtotal{'X_Demand_3'} = 0;
	$rtotal{'X_Demand_4'} = 0;
	for my $k (sort keys %CarrierCapacityLeft) {
		$rtotal{"X_Carrier$k"} = 0;
		$rtotal{"X_CarrierOld$k"} = 0;
	}

	# build the rows
	for my $pj (sort { uc($a->{'CO_Name'} . $a->{'PJ_Description'}) cmp uc($b->{'CO_Name'} . $b->{'PJ_Description'}) } @runnables) {
		$runs .= q|<tr onclick="window.open('/pg/ProjectList?CO_Number=|;
		$runs .= $pj->{'CO_Number'} . q|','')">|;
		$runs .= '<th class="basiclist-row">' . $pj->{'PJ_Number'} . '</th>';
		$runs .= '<th class="basiclist-row">' . $pj->{'PJ_Description'} . '</th>';
		$runs .= '<td class="basiclist" title="CO_Number=' . $pj->{'CO_Number'} . '">' . $pj->{'CO_Name'} . '</td>';
		$runs .= '<td class="basiclist" title="RS_Number=' . $pj->{'RS_Number'} . '">' . $pj->{'RS_Name'} . '</td>';
		$runs .= '<td class="basiclist-right">' . $pj->{'X_CurrentLines'} . '</td>';
		$runs .= '<td class="basiclist-right">' . $pj->{'PJ_Maxline'} . '</td>';
		$runs .= '<td class="basiclist-right">' . $pj->{'X_Demand_1'} . '</td>';
		$runs .= '<td class="basiclist-right">' . $pj->{'X_Demand_2'} . '</td>';
		$runs .= '<td class="basiclist-right">' . $pj->{'X_Demand_3'} . '</td>';
		$runs .= '<td class="basiclist-right">' . $pj->{'X_Demand_4'} . '</td>';

		for my $k (sort keys %CarrierCapacityLeft) {
			$runs .= '<td class="basiclist-right">' . $pj->{"X_Carrier$k"} . '</td>';
			$rtotal{"X_Carrier$k"} += $pj->{"X_Carrier$k"};
		}
		for my $k (sort keys %CarrierCapacityLeft) {
			$runs .= '<td class="basiclist-right">' . $pj->{"X_CarrierOld$k"} . '</td>';
			$rtotal{"X_CarrierOld$k"} += $pj->{"X_CarrierOld$k"};
		}

		$rtotal{'X_CurrentLines'} += $pj->{'X_CurrentLines'};
		$rtotal{'X_Demand_3'} += $pj->{'X_Demand_3'};
		$rtotal{'X_Demand_4'} += $pj->{'X_Demand_4'};

		$runs .= '<td class="basiclist">' . $pj->{'PJ_Type'} . $pj->{'PJ_Type2'} . '</td>';
		$runs .= '<td class="basiclist-right">' . $pj->{'X_Calls'} . '</td>';
		$runs .= '<td class="basiclist-right">' . $pj->{'X_AgentCalls'} . '</td>';
		$runs .= '<td class="basiclist-right">' . 
			sprintf('%d', $pj->{'X_AgentNoAnswer'} + $pj->{'X_AgentBusy'}) . '</td>';


		if ('x' . $pj->{'X_AgentResponse'} . 'x' ne 'xN/Ax') {
			my $hi = "";
			if ($pj->{'X_AgentResponse'} < 0.0019) {
				$hi = "<span style=\"color: #ff6677;font-weight:bold\">?</span>";
			}
			$runs .= "<td class=\"basiclist-right\">" . sprintf('%1.5f', $pj->{'X_AgentResponse'}) 
				. "$hi</td>";
		} else {
			$runs .= "<td class=\"basiclist-right\">" . $pj->{'X_AgentResponse'} . "</td>";
		}

		$runs .= "<td class=\"basiclist-right\">"; 
		if ('x' . $pj->{'X_AgentAbandon'} . 'x' ne 'xN/Ax') {
			if ($pj->{'X_AgentAbandon'} < 0.03) {
				$runs .= sprintf('%1.5f', $pj->{'X_AgentAbandon'});
			} elsif ($pj->{'X_AgentAbandon'} < 0.1) {
				$runs .= sprintf('%1.5f', $pj->{'X_AgentAbandon'}) .
				"<span style=\"color: #ff6677;font-weight:bold\">" .
					"?</span>";
			} else {
				$runs .= "<span style=\"color: #ff6677;font-weight:bold\">" .
					sprintf('%1.5f', $pj->{'X_AgentAbandon'}) .  "</span>";
			}
		} else {
			$runs .= $pj->{'X_AgentAbandon'};
		}
		$runs .= "</td>";

		# ASR
		my $asr = '';
		if ($pj->{'X_Calls'} > 0) {
			$asr = sprintf('%2.1f%%', 100 * ($pj->{'X_Answered'} / $pj->{'X_Calls'}));
		}
		$runs .= '<td class="basiclist-right">' . $asr . '</td>';

		$runs .= "</tr>\n";

	}
	$runs .= '<tr>' .
		'<td colspan=4></td>' .
		'<td class="basiclist-right">' . $rtotal{'X_CurrentLines'} .
		'<td colspan=3></td>' .
		'<td class="basiclist-right">' . $rtotal{'X_Demand_3'} .
		'<td class="basiclist-right">' . $rtotal{'X_Demand_4'} . "</td>";
		
	for my $k (sort keys %CarrierCapacityLeft) {
		$runs .= '<td class="basiclist-right">' . $rtotal{"X_Carrier$k"} . '</td>';
	}
	for my $k (sort keys %CarrierCapacityLeft) {
		$runs .= '<td class="basiclist-right">' . $rtotal{"X_CarrierOld$k"} . '</td>';
	}
	$runs .= "</tr>\n";

	# not runnables
	my @nrheads = ('Id', 'Description', 'Calls Today', 'ASR', 'Last Call', 'Reason');
	my $projects = $dbh->selectall_arrayref(q|
		select project.*, 
			(select sum(RE_Calls) from report 
				where RE_Project = PJ_Number and 
					RE_Date = current_date() and
					RE_Agent = 9999) as Calls_Today,
			(select sum(RE_Answered) from report 
				where RE_Project = PJ_Number and 
					RE_Date = current_date() and
					RE_Agent = 9999) as Answered_Today
		from project
		where 
			(PJ_DateStop >= date_sub(current_date(), interval 1 day) 
			 or PJ_DateStop is null) and
			PJ_Visible = 1
		order by PJ_LastCall desc
	|,  { Slice => {} });

	for my $p (@$projects) {
		$p->{'Calls_Today'} = 0 unless defined($p->{'Calls_Today'});
		my $asr = '';
		if ( ($p->{'Calls_Today'} > 0) && (defined($p->{'Answered_Today'})) ) {
			$asr = sprintf('%2.1f%%', 100 * ($p->{'Answered_Today'} / $p->{'Calls_Today'}));
		}

		if (($p->{'PJ_Status'} eq 'B') && ($p->{'Calls_Today'} == 0)) {
			# no need to display blocked project that haven't dialed anything
			next; 
		}

		my $rp = get_runnable($p->{'PJ_Number'});

		if (($p->{'Calls_Today'} > 0) && (! defined($rp))) {
			my $rmu = q|<tr onclick="window.open('/pg/ProjectList?CO_Number=|;
			$rmu .= $p->{'PJ_CustNumber'} . q|','')">|;
			$rmu .= '<th class="basiclist-row">' . $p->{'PJ_Number'} . '</th>';
			$rmu .= '<th class="basiclist-row">' . $p->{'PJ_Description'} . '</th>';
			$rmu .= '<td class="basiclist-right">' . $p->{'Calls_Today'} . '</td>';
			$rmu .= '<td class="basiclist-right">' . $asr . '</td>';
			$rmu .= '<td class="basiclist">' . $p->{'PJ_LastCall'} . '</td>';
			$rmu .= '<td class="basiclist">' . $p->{'PJ_timeleft'} . '</td>';
			$rmu .= "</tr>\n";

			if ($p->{'PJ_Type'} eq 'C') {
				$cc .= $rmu;
			} else {
				$noruns .= $rmu;
			}
		}
	}

	my $dt = DateTime->now;
	$dt->set_time_zone('America/Los_Angeles');

	
	# warnings
	open(HTML, '>', '/dialer/www/status/allocator-warnings.html') or die "$!";
	if (scalar(@warns)) {
		print HTML "<h2>Warnings</h2><div>\n";
		foreach my $w (@warns) {
			print HTML "<p>$w</p>\n";
		}
		print HTML "</div>\n";
	}
	close(HTML);

	# tables
	open(HTML, '>', '/dialer/www/status/allocator-tables.html') or die "$!";
	print HTML "\n<h2>Running Projects  (" . $dt->ymd . ' ' . $dt->hms . 
		' Pacific)</h2>';
	print HTML "<table cellspacing=1>\n<tr>";
	for my $th (@rheads) { print HTML "<th class=\"basiclist-col\">$th</th>"; }
	print HTML "</tr>\n$runs</table>\n";

	print HTML "<h2>Cold Calling</h2><table cellspacing=1>\n<tr>";
	for my $th (@nrheads) { print HTML "<th class=\"basiclist-col\">$th</th>"; }
	print HTML "</tr>\n$cc</table>\n";

	print HTML "<h2>Not Running</h2><table cellspacing=1>\n<tr>";
	for my $th (@nrheads) { print HTML "<th class=\"basiclist-col\">$th</th>"; }
	print HTML "</tr>\n$noruns</table>\n";
	close(HTML);
}

###############################################################################
# Main loop starts here
###############################################################################

$| = 1; # unbuffered output

while (1) {
	logmsg("- - - - - - - - - - - -");
	$dbh = DialerUtils::db_connect(); # connect to the database

	@warns = ();
	cleanup();
    build_runnable_projects();
	adjust_demand_for_leads_left();
	check_customer_maxlines();
	check_reseller_maxlines();
	adjust_for_overall_capacity(); # sets X_Demand_4
	stop_nonrunnables();
	normalize_route_plans();
	determine_carrier_capacity();
	distribute_to_carriers();
	assign_lines();
	check_runnable_warnings();
	graphing();
	build_stats_page();

    $dbh->disconnect;

	sleep 15;
}
