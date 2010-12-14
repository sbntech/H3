#!/usr/bin/perl

use strict;
use warnings;
use lib '/dialer/convert';
use lib '/dialer/www/perl';
use DialerUtils;
use DateTime;
use File::Temp qw( tempfile );
use Time::HiRes qw( gettimeofday tv_interval );

for my $prog (`ps -o pid= -C CallResultProcessing.pl`) {
	if ($prog != $$) {
		die "Not continuing, already running with pid=$prog";
	}
}

DialerUtils::daemonize();
open(PID, ">", "/var/run/CallResultProcessing.pid");
print PID $$;
close(PID);

# ENHANCE HERE!
	# count DA as answered

my $running = 1;
my $dbh;
my $nowdt;
my $startpoint;
my $trancount;
my $anomalystr;
my $LOG;
open ($LOG, '>>', '/var/log/CallResultProcessing.log') or die "cannot open log file: $!";
my $old_fh = select($LOG); $| = 1; select($old_fh); # unbufferd io on the log

my @DISPOSITIONS = qw( BA 			FA 			  MA 		     MN 			NA 			BU       HU                 HN HA              AC                AN               AB           DA                 EC          TESTOK TESTFAULT ER AS );
my @REPORTCOLS =   qw( RE_Badnumber RE_Faxmachine RE_Ansrmachine RE_Ansrmachine RE_Noanswer RE_Bussy RE_Hungupduringmsg na RE_Aftermessage RE_Connectedagent RE_Agentnoanswer RE_Agentbusy RE_Hungupb4connect RE_Noanswer na     na        na na );
my @DISPPRESSONE = qw( 0  			0  			  0  		     0  			0  			0        0                  0  0               1                 1                1            0                  0           0      0         0  0  );
my @DISPANSWERED = qw( 0  			1  			  1  		     1  			0  			0        1                  1  1               1                 0                0            0                  0           1      1         0  0  );
my @PROJPLOTCOLS = qw( NonConnect   Machine       Machine        Machine        NonConnect  NonConnect Live             Live Live          Transfer          LostTransfer     LostTransfer LostTransfer       NonConnect Live NonConnect NonConnect Skip); # for PlotData

my @lnstats = ('Used', 'Free', 'Open', 'Stop', 'Error', 'Block', 'Data');
my @theads = ('Name','NVR','Stat', 'Conn', 'P1', 'Human', 'Mach', 'Shorts', 'S/H', 'S/P1', 'Calls Day','Calls Hr','Started','Last Used',@lnstats,'Lines');

my $stats; 
	# $stats->{Dialer}{D101}{ProspectCalls|Connects|Human|AgentCalls|DurationTotal|ShortCalls} 
	# $stats->{Line}{D101}{<lineinfo>}{Connects|CarrierBusy|Bad|Count}
	# $stats->{Total}

my $HTML;


sub flog {
	my $lvl = shift;
	my $msg = shift;

	return if $lvl eq 'DEBUG';

	my ($dt, $tm) = DialerUtils::local_datetime();
	print $LOG "$dt $tm $lvl: $msg\n";
}

sub exit_handler {
	my $sig = shift;
	flog('TERMINATING', "SIG$sig caught");
	$running = 0;
}

$SIG{'INT'} = \&exit_handler;
$SIG{'QUIT'} = \&exit_handler;
$SIG{'TERM'} = \&exit_handler;


sub anomaly {
	my $msg = shift;
	my ($dt, $tm) = DialerUtils::local_datetime();

	$anomalystr .= "$dt $tm: $msg\n";
}

sub parse_result {
	my $rline = shift;

	# CDR format: <project>,<unix timestamp Eastern>,<called number>,<DNC flag>,<actual duration>,<disposition>,<dialerid>,<line info>,<extra info>,<related number>,<survey results>,<agent number or 9999>
	chomp($rline);
	if ($rline !~ /(\d*),(\d*),(\d*),(Y|N),(\d*),([A-Z]*),([^,]*),([^,]*),([^,]*),(\d*),([^,]*),(\d*)/) {
		anomaly("bad format in raw result line [$rline]");
		return;
	}
	
	    #  0    1    2     3     4    5     6     7     8
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($2);

	my $res = {
		PJ_Number => $1,
		'DateTime' => sprintf('%02d-%02d-%02d,%02d:%02d:%02d',
			1900 + $year, $mon + 1, $mday, $hour, $min, $sec),
		CalledNumber => $3,
		DoNotCallFlag => $4,
		ActualDuration => $5,
		DispositionCode => $6,
		DialerId => $7,
		LineInfo => $8,
		ExtraInfo => $9,
		RelatedNumber => $10,
		SurveyResults => $11,
		AgentNumber => $12,
	};

	if (! grep(/$6/, @DISPOSITIONS)) {
		anomaly("$6 is not a recognized disposition in $rline");
	}
			
	$res->{'LoopTime'} = 0.0;
	if ($res->{'ExtraInfo'} =~ /.*LT-([.0-9]*).*/) {
		$res->{'LoopTime'} = $1;
	}
					
	$res->{'CarrierBusyFlag'} = 'N';
	if (($res->{'DispositionCode'} eq "BU") && ($res->{'ExtraInfo'} =~ /-(546|556|554)-/)) {
		$res->{'CarrierBusyFlag'} = 'Y';
	}

	return $res;
}

sub dbload {
	my ($pjid, $p, $c, $r) = @_;

	my $rref = $dbh->selectrow_hashref("select * from project
		where PJ_Number = $pjid");

	if (! defined($rref)) {
		flog('FATAL', "database error looking up project $pjid");
		return;
	}

	for my $col (keys %{$rref}) {
		$p->{$pjid}->{$col} = $rref->{$col};
	}

	my $cust = $p->{$pjid}->{'PJ_CustNumber'};
	if (! defined($c->{$cust})) {
		$rref = $dbh->selectrow_hashref("select * from customer
			where CO_Number = $cust");

		if (! defined($rref)) {
			flog('FATAL', "database error looking up customer $cust");
			return;
		}

		for my $col (keys %{$rref}) {
			$c->{$cust}->{$col} = $rref->{$col};
		}
	}

	my $reseller = $c->{$cust}->{'CO_ResNumber'};
	if (($reseller > 1) && (! defined($r->{$reseller}))) {
		$rref = $dbh->selectrow_hashref("select * from reseller
			where RS_Number = $reseller");

		if (! defined($rref)) {
			flog('FATAL', "database error looking up reseller $reseller");
			return;
		}

		for my $col (keys %{$rref}) {
			$r->{$reseller}->{$col} = $rref->{$col};
		}
	}
}

sub gather_stats {
	my $result = shift;

	if ($result->{'LoopTime'} > 0.0) {
		my $gi = int($result->{'LoopTime'}) + 1;
		$gi = 4 if $gi >= 4;
		$stats->{Total}{"LoopTime-$gi"}++;
		$stats->{Total}{"LoopTime-Total"}++;
	}

	my $res = $result->{'DispositionCode'};
	my $dur = $result->{'ActualDuration'};
		
	$stats->{'Line'}{$result->{'DialerId'}}{$result->{'LineInfo'}}{Count}++;

	if ($result->{'CarrierBusyFlag'} eq 'Y') {
		$stats->{'Line'}{$result->{'DialerId'}}{$result->{'LineInfo'}}{CarrierBusy}++;
	}
		
	if ($res eq 'BA') {
		$stats->{'Line'}{$result->{'DialerId'}}{$result->{'LineInfo'}}{Bad}++;
	}
		
	if (($res eq 'HA') || ($res eq 'FA') || ($res eq 'MA') || ($res eq 'HU') || ($res eq 'MN')) {
		$stats->{'Line'}{$result->{'DialerId'}}{$result->{'LineInfo'}}{Connects}++;
		$stats->{'Dialer'}{$result->{'DialerId'}}{Connects}++;
		$stats->{'Total'}{Connects}++;
	}

	if ($res ne 'AS') {
		if (($res eq 'AC') || ($res eq 'AB') || ($res eq 'AN') || ($res eq 'DA')) {
			$stats->{'Dialer'}{$result->{'DialerId'}}{AgentCalls}++;
			$stats->{'Total'}{AgentCalls}++;
		} else {
			$stats->{'Dialer'}{$result->{'DialerId'}}{ProspectCalls}++;
			$stats->{'Total'}{ProspectCalls}++;
		}
	}

	if ($dur > 0) {
		if ($dur < 7) {
			$stats->{'Dialer'}{$result->{'DialerId'}}{ShortCalls}++;
		}

		if ($dur < 1800) {
			# not counting anomalies
			$stats->{'Dialer'}{$result->{'DialerId'}}{DurationTotal} += $dur;
			$stats->{'Total'}{DurationTotal} += $dur;
		}
	}

	if (($res eq 'HA') || ($res eq 'HU')) {
		$stats->{'Dialer'}{$result->{'DialerId'}}{Human}++;
		$stats->{'Total'}{Human}++;
	}

}

sub readqfile {
	my ($f, $c, $p, $r, $s, $plot) = @_;

	my $QFILE;
	if (! open($QFILE, '<', $f)) {
		flog('ERROR', "Unable to open $f:$!");
		return;
	}

	while (my $rline = <$QFILE>) {
		my $result = parse_result($rline);

		next unless defined($result);

		if (! defined($p->{$result->{'PJ_Number'}})) {
			dbload($result->{'PJ_Number'}, $p, $c, $r);
		}

		# discard anomalies - Sam is unable to prevent them
		if ($result->{'ActualDuration'} >= 3600) {
			anomaly("Ignoring long result: " .
			$result->{'DateTime'} . ',' .
			$result->{'CalledNumber'} . ',' .
			$result->{'ActualDuration'} . ',' .
			$result->{'DispositionCode'} . ',' .
			$result->{'DialerId'} . '-' . $result->{'LineInfo'} . ',' .
			$result->{'ExtraInfo'});
			next;
		}
		if (($result->{'AgentNumber'} == 9) || ($result->{'AgentNumber'} == 99) || ($result->{'AgentNumber'} == 999)) {
			anomaly("Fixing bad agent number in cdr [$rline] " .
			$result->{'DateTime'} . ',' .
			$result->{'CalledNumber'} . ' for project: ' .
			$result->{'PJ_Number'} . ' from ' .
			$result->{'DialerId'} . '-' . $result->{'LineInfo'} );
			$result->{'AgentNumber'} = 9999;
		}
		$trancount++;

		$result->{'VOIPCall'} = substr($result->{'CalledNumber'},5,5) eq '00000';

		flog('DEBUG', "trancount=$trancount, CDR for " . $result->{'CalledNumber'} . " on project " . $result->{'PJ_Number'} . " ====>>>");
		gather_stats($result);
		
		$s->{$result->{'DialerId'}}++;
		my $proj = $p->{$result->{'PJ_Number'}};
		my $cust = $c->{$proj->{'PJ_CustNumber'}};
		my $resl;
		if ($cust->{'CO_ResNumber'} > 1) {
			$resl = $r->{$cust->{'CO_ResNumber'}};
		}

		my $cdrEnd = '';
		if ($result->{'DoNotCallFlag'} eq 'Y') {
			$cdrEnd = '2';
		
			# save number for customer DNC update 
			flog('DEBUG', "Queued " . $result->{'CalledNumber'} . " for dnc list of customer " . $proj->{'PJ_CustNumber'});
			push @{$cust->{'DoNotCall'}}, $result->{'CalledNumber'};
		}
		$cdrEnd .= $result->{'SurveyResults'};
		$cdrEnd .= $result->{'RelatedNumber'};
		if (length($cdrEnd) > 0) {
			$cdrEnd = ",$cdrEnd";
		}

		if ((length($result->{'RelatedNumber'}) == 10) &&
				($result->{'AgentNumber'} != 9999)) {
			# agent - prospect connection of some sort
			push @{$proj->{'BridgedNumber'}}, $result;
		}

		# number has been used
		push @{$proj->{'UsedNumber'}}, $result;

		# non-connects - that we don't want to call again
		if (($result->{'DispositionCode'} eq "NA") || 
			(($result->{'DispositionCode'} eq "BU") && ($result->{'CarrierBusyFlag'} ne 'Y')) ||
			($result->{'DispositionCode'} eq "FA")) { 
			$proj->{'NonConnectedNumber'} .= $result->{'CalledNumber'} . "\n";
		}

		# non-connects - that we don't want to call again
		if ($result->{'DispositionCode'} eq "BA") { 
			$proj->{'BadNumber'} .= $result->{'CalledNumber'} . "\n";
		}

		# save a CDR for writing to file
		$proj->{'CDR'} .= 
			$result->{'DateTime'} . ',' .
			$result->{'CalledNumber'} . ',' .
			$result->{'ActualDuration'} . ',' .
			$result->{'DispositionCode'} . ',' .
			$result->{'DialerId'} . '-' . $result->{'LineInfo'} . ',' .
			$result->{'ExtraInfo'} .
			$cdrEnd . # it has the comma
			chr(13) . chr(10); # DOS line ending

		$proj->{$result->{'DispositionCode'}}{$result->{'AgentNumber'}}++;
		$proj->{'AgentNumbers'}{$result->{'AgentNumber'}} = 1;
		$proj->{'CO_RoundedDuration'}{$result->{'AgentNumber'}} = 0 unless defined($proj->{'CO_RoundedDuration'}{$result->{'AgentNumber'}});
		$proj->{'RS_RoundedDuration'}{$result->{'AgentNumber'}} = 0 unless defined($proj->{'RS_RoundedDuration'}{$result->{'AgentNumber'}});
		$proj->{'CO_RoundedIPDuration'}{$result->{'AgentNumber'}} = 0 unless defined($proj->{'CO_RoundedIPDuration'}{$result->{'AgentNumber'}});
		$proj->{'RS_RoundedIPDuration'}{$result->{'AgentNumber'}} = 0 unless defined($proj->{'RS_RoundedIPDuration'}{$result->{'AgentNumber'}});
		$proj->{'StandbyIPDuration'}{$result->{'AgentNumber'}} = 0 unless defined($proj->{'StandbyIPDuration'}{$result->{'AgentNumber'}});
		$proj->{'MachineDuration'}{$result->{'AgentNumber'}} = 0 unless defined($proj->{'MachineDuration'}{$result->{'AgentNumber'}});
		$proj->{'StandbyDuration'}{$result->{'AgentNumber'}} = 0 unless defined($proj->{'StandbyDuration'}{$result->{'AgentNumber'}});

		if ($result->{'DispositionCode'} eq 'TESTOK') {
			$proj->{'TestCall'} = 1;
		}

		if (($result->{'ActualDuration'} == 0) && 
			(
			 ($result->{'DispositionCode'} eq 'FA') ||
			 ($result->{'DispositionCode'} eq 'MA') ||
			 ($result->{'DispositionCode'} eq 'MN') ||
			 ($result->{'DispositionCode'} eq 'HU') ||
			 ($result->{'DispositionCode'} eq 'HN') ||
			 ($result->{'DispositionCode'} eq 'HA') ||
			 ($result->{'DispositionCode'} eq 'AC') ||
			 ($result->{'DispositionCode'} eq 'DA') ||
			 ($result->{'DispositionCode'} eq 'TESTOK') ||
			 ($result->{'DispositionCode'} eq 'TESTFAULT')
			)) {
			anomaly("Unexpected zero duration in: $rline");
			if ($cust->{'CO_Billingtype'} eq 'T') {
				$result->{'ActualDuration'} = 1; # ENHANCE HERE! don't correct like this
			} else {
				$proj->{'0_14_seconds'}{$result->{'AgentNumber'}}++; # ENHANCE HERE! don't correct like this
			}
		}

		$plot->{'Dials'}++ unless $result->{'DispositionCode'} eq 'AS';
		if ($result->{'CarrierBusyFlag'} eq 'Y') {
			$plot->{'CarrierBusy'}++;
		}
		if ($result->{'ActualDuration'} > 0) {
			$plot->{'Connects'}++ unless $result->{'DispositionCode'} eq 'AS';
			if (($result->{'DispositionCode'} eq 'AC') ||
				($result->{'DispositionCode'} eq 'AN') ||
				($result->{'DispositionCode'} eq 'AB') ||
				($result->{'DispositionCode'} eq 'DA')) {

				$plot->{'AgentCalls'}++;
			}
		}

		# durations
		if (($result->{'ActualDuration'} > 0) && ($result->{'DispositionCode'} ne 'DA') && ($result->{'DispositionCode'} ne 'AS')) { # ENHANCE HERE! - remove the DA check
			flog('DEBUG', "have seconds to bill: " . $result->{'ActualDuration'});
			$proj->{'ActualDuration'}{$result->{'AgentNumber'}} += $result->{'ActualDuration'};
			my $ctime = $result->{'ActualDuration'};
			if ($cust->{'CO_Billingtype'} eq 'T') { # ENHANCE HERE! - produce rounded times for fixed cost use 6 if roundby=0
				if ($cust->{'CO_Min_Duration'} > $ctime) {
					$ctime = $cust->{'CO_Min_Duration'};
				}
				if ($cust->{'CO_RoundBy'} > 0) {
					$ctime = int(($ctime - 1 + $cust->{'CO_RoundBy'}) / $cust->{'CO_RoundBy'}) * $cust->{'CO_RoundBy'};
				}
			}
			if ($result->{'VOIPCall'}) {
				$proj->{'CO_RoundedIPDuration'}{$result->{'AgentNumber'}} += $ctime;
				flog('DEBUG', "    Customer VOIP rounded seconds: $ctime");
			} else {
				$proj->{'CO_RoundedDuration'}{$result->{'AgentNumber'}} += $ctime;
				flog('DEBUG', "    Customer rounded seconds: $ctime");
			}

			if ($cust->{'CO_ResNumber'} > 1) {
				my $rctime = $result->{'ActualDuration'};
				if ($resl->{'RS_Min_Duration'} > $rctime) {
					$rctime = $resl->{'RS_Min_Duration'};
				}
				if ($resl->{'RS_RoundBy'} > 0) {
					$rctime = int(($rctime - 1 + $resl->{'RS_RoundBy'}) / $resl->{'RS_RoundBy'}) * $resl->{'RS_RoundBy'};
				} 
				if ($result->{'VOIPCall'}) {
					$proj->{'RS_RoundedIPDuration'}{$result->{'AgentNumber'}} += $rctime;
					flog('DEBUG', "    Reseller VOIP rounded seconds: $ctime");
				} else {
					$proj->{'RS_RoundedDuration'}{$result->{'AgentNumber'}} += $rctime;
					flog('DEBUG', "    Reseller rounded seconds: $ctime");
				}
			}

			if (($result->{'DispositionCode'} eq 'MA') || ($result->{'DispositionCode'} eq 'MN')) {
				$proj->{'MachineDuration'}{$result->{'AgentNumber'}} += $ctime;
			}

			if ($ctime >= 15*60) {
				$proj->{'15_over_minutes'}{$result->{'AgentNumber'}}++;
			} elsif ($ctime >= 10*60) {
				$proj->{'10_15_minutes'}{$result->{'AgentNumber'}}++;
			} elsif ($ctime >= 5*60) {
				$proj->{'5_10_minutes'}{$result->{'AgentNumber'}}++;
			} elsif ($ctime >= 3*60) {
				$proj->{'3_5_minutes'}{$result->{'AgentNumber'}}++;
			} elsif ($ctime >= 2*60) {
				$proj->{'2_3_minutes'}{$result->{'AgentNumber'}}++;
			} elsif ($ctime >= 60) {
				$proj->{'1_2_minutes'}{$result->{'AgentNumber'}}++;
			} elsif ($ctime >= 30) {
				$proj->{'30_59_seconds'}{$result->{'AgentNumber'}}++;
			} elsif ($ctime >= 15) {
				$proj->{'15_29_seconds'}{$result->{'AgentNumber'}}++;
			} else {
				$proj->{'0_14_seconds'}{$result->{'AgentNumber'}}++;
			}
		}
		if (($result->{'ActualDuration'} > 0) && ($result->{'DispositionCode'} eq 'AS')) { 
			if ($result->{'VOIPCall'}) {
				$proj->{'StandbyIPDuration'}{$result->{'AgentNumber'}} += $result->{'ActualDuration'};
				flog('DEBUG', "    Standby time was on IP: " . $result->{'ActualDuration'});
			} else {
				$proj->{'StandbyDuration'}{$result->{'AgentNumber'}} += $result->{'ActualDuration'};
			}
		}

		flog('DEBUG', "<<<====");
	}

	close $QFILE;
}

sub block_lines {

	my $lines = shift;
	my ($dt, $tm) = DialerUtils::local_datetime();

	unless(open BLOCKLOG, '>>', '/dialer/www/status/block-log.txt') {
		warn "opening block log failed: $!";
		return;
	}

	for my $d (keys %$lines) {

		next unless (substr($d,0,1) eq 'D');

		for my $li (keys %{$lines->{$d}}) {
			my $i = $lines->{$d}{$li};
			my ($t1, $chan, $task) = (0, 0, 0);
			if ($li =~ /^(\d*)-(\d*)-(\d*)/) {
				($t1, $chan, $task) = ($1, $2, $3);
			}

			if ($i->{Count} > 20) {
				
				my $CBratio = 0;
				my $CB = 0;
				if (defined($i->{CarrierBusy})) {
					$CB = $i->{CarrierBusy};
					$CBratio = $CB / $i->{Count};
				}

				my $BAratio = 0;
				my $BA = 0;
				if (defined($i->{Bad})) {
					$BA = $i->{Bad};
					$BAratio = $BA / $i->{Count};
				}

				my $NonConnRate = 1;
				my $Conn = 0;
				if (defined($i->{Connects})) {
					$Conn = $i->{Connects};
					$NonConnRate = 1 - ($Conn / $i->{Count});
				}

				if (($BAratio > 0.80) || ($CBratio > 0.90) || ($NonConnRate > 0.95)) {
					my $reason = sprintf('c%0.2f b%0.2f nc%0.2f', 
						$CBratio, $BAratio, $NonConnRate);
					my $c = $dbh->do(
						"update line set ln_status = 'B', ln_action = '888888',
						ln_lastused = now(), ln_reson = '$reason' where
						ln_status != 'E' and ln_status != 'B' and
						ln_switch = '$d' and ln_board = '$t1' and
						ln_channel = '$chan'");

					print BLOCKLOG "$dt $tm: $d-$t1-$chan autoblocked " .
						sprintf('BA-ratio: %0.2f  CB-ratio: %0.2f  NonConnRatio: %0.2f',
						$BAratio, $CBratio, $NonConnRate) . 
						"  Count: " . $i->{Count} . "  Bad: $BA  Conn: $Conn  CB: $CB\n";

					$i->{Count} = 0;
					$i->{Connects} = 0;
					$i->{Bad} = 0;
					$i->{CarrierBusy} = 0;
				}
			}
		}
	}

	close BLOCKLOG;

}

# .............................................................................
sub print_dialer_table {
	my $sql = shift;

	print $HTML "<h2>Dialers</h2>\n";
	print $HTML "<table cellspacing=1>\n<tr>";
	for my $th (@theads) { print $HTML "<th class=\"basiclist-col\">$th</th>"; }
	print $HTML "</tr>\n";

	my $sw = $dbh->selectall_arrayref($sql, { Slice => {} });
	my %dtotals = (SW_callsday => 0, SW_callsuur => 0, grand => 0);
	for my $stat (@lnstats) {
		my $s = substr($stat,0,1);
		$dtotals{$s} = 0;
	}

	my %extracols;

	for my $switch (@$sw) {

		my $swid = $switch->{'SW_ID'};
		if ((defined($stats->{Dialer}{$swid})) &&
			(defined($stats->{Dialer}{$swid}{ProspectCalls})) &&
			(defined($stats->{Dialer}{$swid}{Connects})) &&
			($stats->{Dialer}{$swid}{ProspectCalls} > 0) &&
			($stats->{Dialer}{$swid}{Connects} > 0)) {

			my $dstat = $stats->{Dialer}{$swid};
			$dstat->{Human} = 0 unless defined($dstat->{Human});
			my $mach = $dstat->{Connects} - $dstat->{Human};
			$dstat->{AgentCalls} = 0 unless defined($dstat->{AgentCalls});
			$dstat->{ShortCalls} = 0 unless defined($dstat->{ShortCalls});

			%extracols = (
				'Connects' => sprintf('%d (%2.0f%%)', 
								$dstat->{Connects}, 
								100 * $dstat->{Connects} / $dstat->{ProspectCalls}),
				'P1' => $dstat->{AgentCalls},
				'Human' => sprintf('%d (%2.0f%%)', 
								$dstat->{Human}, 
								100 * $dstat->{Human} / $dstat->{Connects}),
				'ShortCalls' => sprintf('%d (%2.2f%%)', 
								$dstat->{ShortCalls}, 
								100 * $dstat->{ShortCalls} / $dstat->{Connects}),
				'Machine' => sprintf('%d (%2.0f%%)', 
								$mach, 100 * $mach / $dstat->{Connects}),
				'Secs-Human' => $dstat->{Human} > 0 ? int($dstat->{DurationTotal} / $dstat->{Human}) : 0,
				'Secs-P1' => $dstat->{AgentCalls} > 0 ? int($dstat->{DurationTotal} / $dstat->{AgentCalls}) : 0);
		} else {
			%extracols = (
				'Connects' => 0,
				'P1' => 0,
				'Human' => 0,
				'ShortCalls' => 0,
				'Machine' => 0,
				'Secs-Human' => 0,
				'Secs-P1' => 0);
		}

		print $HTML "<tr>";
		print $HTML "<th class=\"basiclist-row\"
			title =\"IP=" . $switch->{'SW_IP'} . "\" ><a href=\"/pg/Switch?switch=" .
			$switch->{'SW_ID'} . "\">" . $switch->{'SW_ID'} . '</a></th>';

		# do line info here even though its columns are later
		my $notBlocked = 0; # need this now-ish
		my $lineStats = '';
		my $lnres = $dbh->selectall_hashref('select ln_status, count(*) as total ' .
			"from line where ln_switch = '" . $switch->{'SW_ID'} . 
			"' group by ln_status", 'ln_status');

		my $dtot = 0;
		for my $stat (@lnstats) {
			my $s = substr($stat,0,1);
			my $t = $lnres->{$s}->{'total'};
			$t = 0 unless defined($t);
			$notBlocked += $t unless ($s eq 'B');
			$dtot += $t;
			$dtotals{$s} += $t;
			$dtotals{'grand'} += $t;
			$lineStats .= '<td class="basiclist">' . "$t</td>";
		}
		$lineStats .= '<td class="basiclist">' . "$dtot</td>";

		print $HTML '<td class="basiclist">' . $switch->{'SW_databaseSRV'} . '</td>';
		print $HTML '<td class="basiclist">' . $switch->{'SW_Status'} . '</td>';
		print $HTML '<td class="basiclist">' . $extracols{'Connects'} . '</td>';
		print $HTML '<td class="basiclist">' . $extracols{'P1'} . '</td>';
		print $HTML '<td class="basiclist">' . $extracols{'Human'} . '</td>';
		print $HTML '<td class="basiclist">' . $extracols{'Machine'} . '</td>';
		print $HTML '<td class="basiclist">' . $extracols{'ShortCalls'} . '</td>';
		print $HTML '<td class="basiclist">' . $extracols{'Secs-Human'} . '</td>';
		print $HTML '<td class="basiclist">';
		if ($extracols{'Secs-P1'} > 5000) {
			print $HTML '<span style="color: red; font-weight: bold">' . $extracols{'Secs-P1'} . '</span>';
		} else {
			print $HTML $extracols{'Secs-P1'};
		}
		print $HTML '</td>';
		print $HTML '<td class="basiclist">' . $switch->{'SW_callsday'} . '</td>';
		print $HTML '<td class="basiclist">' . $switch->{'SW_callsuur'} . '</td>';
		print $HTML '<td class="basiclist">' . $switch->{'SW_start'} . '</td>';
		print $HTML '<td class="basiclist">' . $switch->{'lastused'} . '</td>';

		$dtotals{'SW_callsday'} += $switch->{'SW_callsday'};
		$dtotals{'SW_callsuur'} += $switch->{'SW_callsuur'};

		print $HTML $lineStats;
		print $HTML "</tr>\n";
	}

	print $HTML '<tr><td colspan="10"></td>';
	print $HTML '<td class="basiclist">' . $dtotals{'SW_callsday'} . '</td>';
	print $HTML '<td class="basiclist">' . $dtotals{'SW_callsuur'} . '</td>';
	print $HTML '<td colspan="2"></td>';
	for my $stat (@lnstats) {
		my $s = substr($stat,0,1);
		print $HTML '<td class="basiclist">' . $dtotals{$s} . '</td>';
	}
	print $HTML '<td class="basiclist">' . $dtotals{'grand'} . '</td></tr>';

	print $HTML "</table>\n</body></html>\n";

}
sub print_status {

	my ($dt, $tm) = DialerUtils::local_datetime();

	unless(open($HTML, '>', '/dialer/www/status/result-stats.html.tmp')) {
		warn "Could not open the html page: $!";
		return;
	}

	print $HTML "<html><head><title>$tm  Result Stats</title>\n";
	print $HTML q(<link rel="stylesheet" TYPE="text/css" HREF="/glm.css">);
	print $HTML q|</head><body onload="var d = new Date(); setTimeout('location.reload()',(69 - d.getSeconds())*1000)">|;
	print $HTML "<table cellspacing=10><tr><td style=\"vertical-align:top\">";

	my @theads = ( 'Prospect Call Count', 'Agent Call Count', 'Connects', 'Human', 'Machines', 'Duration');

	my $mach = $stats->{Total}{Connects} - $stats->{Total}{Human};
	my @tvalues = (
		$stats->{Total}{ProspectCalls},
		$stats->{Total}{AgentCalls},
		$stats->{Total}{Connects} . ($stats->{Total}{ProspectCalls} > 0 ? sprintf(' (%4.1f)', 100*$stats->{Total}{Connects}/$stats->{Total}{ProspectCalls}) : ''),
		$stats->{Total}{Human} . ($stats->{Total}{Connects} > 0 ? sprintf(' (%4.1f)', 100*$stats->{Total}{Human}/$stats->{Total}{Connects}) : ''),
		$mach . ($stats->{Total}{Connects} > 0 ? sprintf(' (%4.1f)', 100*$mach/$stats->{Total}{Connects}) : ''),
		$stats->{Total}{DurationTotal},
	);

	print $HTML "<h2 id=\"totals\">Result Totals</h2>\n";
	print $HTML "<table cellspacing=1>";
	for (my $tk = 0; $tk < scalar(@theads); $tk++) {
		print $HTML "<tr><th class=\"basiclist-col\">" .
			$theads[$tk] . "</th><td class=\"basiclist\">" . 
			$tvalues[$tk] . "</td></tr>";
	}
	print $HTML "</table>\n";

	my $DialsRecord		= '2009-02-04'; # 12449507
	my $MinutesRecord	= '2009-01-28'; #  3175151
	my $RevenueRecord	= '2009-02-05'; #    49572.41

	my $rep = $dbh->selectall_arrayref("select RE_Date, sum(RE_Calls) as Dials, format(sum((IF(RS_Number = 1,RE_Tot_Sec,RE_Res_Sec))/60),0) as Minutes, format(sum(if(CO_ResNumber = 1, RE_Tot_Cost, if(RS_DistribFactor > 0, RE_res_tot_cost / RS_DistribFactor, RE_res_tot_cost))),2) as Revenue from report,customer,project,reseller where PJ_Number = RE_Project and CO_Number = PJ_CustNumber and RS_Number = CO_ResNumber and (re_date > date_sub(current_date(), interval 8 day) or re_date = '$DialsRecord' or re_date = '$MinutesRecord' or re_date = '$RevenueRecord') group by RE_Date order by RE_Date desc", { Slice => {}});

	print $HTML "</td><td style=\"vertical-align:top\">";
	print $HTML "<h2>Report Totals</h2>\n";
	print $HTML "<table cellspacing=1><tr><th class=\"basiclist-col\">Date</th><th class=\"basiclist-col\">Dials</th><th class=\"basiclist-col\">Minutes</th><th class=\"basiclist-col\">Revenue</th></tr>";
	for my $r (@$rep) {
		print $HTML "<tr><td class=\"basiclist\">" . $r->{'RE_Date'} . "</td>"
			. "<td class=\"basiclist-right\">" . $r->{'Dials'} . "</td>"
			. "<td class=\"basiclist-right\">" . $r->{'Minutes'} . "</td>"
			. "<td class=\"basiclist-right\">" . $r->{'Revenue'} . "</td>"
			. "</tr>";
	}
	print $HTML "</table>\n";


	print $HTML "</td><td style=\"vertical-align:top\">";
	print $HTML "<h2 id=\"getoutline\">GETOUTLINE response</h2>\n";
	print $HTML "<table cellspacing=1><tr>";
	@theads = ('Seconds', 'Count', 'Percent');
	for my $th (@theads) { print $HTML "<th class=\"basiclist-col\">$th</th>"; }
	print $HTML "</tr>\n";

	my $go_total = $stats->{Total}{'LoopTime-Total'};
	$go_total = 0 unless defined $go_total;

	for (my $g = 1; $g < 5; $g++) {
		my $col1 = sprintf('%d - %d', $g - 1, $g);
		$col1 = "4+" if ($g == 4);
		my $col2 = '0';
		my $col3 = '0%';
		my $gor = $stats->{Total}{"LoopTime-$g"};
		if (($go_total > 0) && (defined($gor))) {
			$col2 = $gor;
			$col3 = sprintf('%5.2f%%', (100 * $gor / $go_total));
		}

		print $HTML "<th class=\"basiclist-row\">$col1</th>
			<td class=\"basiclist\">$col2</td>
			<td class=\"basiclist\">$col3</td>
			</tr>\n";
	}
	print $HTML "<th class=\"basiclist-row\">Total</th>
		<td class=\"basiclist\">$go_total</td>
			<td class=\"basiclist\">100.00%</td>
		</tr>\n";
	print $HTML "</table>\n";

	print $HTML "</td><td style=\"vertical-align:top\">";
	print $HTML "<h2 id=\"getoutline\">Logs</h2>\n";
	print $HTML q|<a href="/status/block-log.txt">Block Log</a><br/>|;
	print $HTML q|<a href="/status/anomaly-log.txt">Anomaly Log</a><br/>|;

	print $HTML "</td></tr></table>";

	print_dialer_table("select switch.*, (select if(max(ln_lastused),max(ln_lastused),'Unknown') from line where ln_switch = sw_id) as lastused from switch where SW_databaseSRV != '10.80.2.9' order by sw_id");

	print $HTML "</body></html>\n";
	close($HTML);
	rename('/dialer/www/status/result-stats.html.tmp', '/dialer/www/status/result-stats.html');

}

sub do_queue {
	my $QDIR;
	if (! opendir($QDIR, '/dialer/call-results-queue')) {
		flog('FATAL', "failed to open queue dir: $!");
		die "failed to open qdir: $!";
	}

	my $sql;
	my %resellers; # all reseller columns
	my %customers; # all the customer colums
	my %projects; # all the project columns
	my %switches; # holds calls made on each switch for updating table switch
	my %plots # holds counts used for plotting
			= (Dials => 0, AgentCalls => 0, Connects => 0, CarrierBusy => 0);

	for my $ent (readdir($QDIR)) {
		next if $ent =~ /^\./;
		flog('INFO', "processing entry: $ent");
		my $file = "/dialer/call-results-queue/$ent";

		readqfile($file, \%customers, \%projects, \%resellers, \%switches, \%plots);
		unlink($file);
	}
    closedir $QDIR;

	# process the amalgamated data
	for my $pjid (keys %projects) {
		my $proj = $projects{$pjid};

		my $c = $customers{$proj->{'PJ_CustNumber'}};
		flog('DEBUG', "[[[[ Amalgamated project: $pjid   CO_Rate=" . $c->{'CO_Rate'} . ", CO_AgentIPRate=" . $c->{'CO_AgentIPRate'});

		my %reprows;

		for my $Agent (keys %{$proj->{'AgentNumbers'}}) {
			# initialize some things
			for my $repcol (@REPORTCOLS) {
				next if $repcol eq 'na';
				$reprows{$Agent}{$repcol} = 0;
			}
			$reprows{$Agent}{'RE_Answered'} = 0;
			$reprows{$Agent}{'RE_Pressedtone'} = 0;
			$reprows{$Agent}{'RE_Calls'} = 0;

			flog('DEBUG', "    ---- Agent=$Agent ----");

			# dispositions
			for (my $disppos = 0; $disppos < scalar(@DISPOSITIONS); $disppos++) {
				my $disp     = $DISPOSITIONS[$disppos];
				my $repcol   = $REPORTCOLS[$disppos];
				my $pplotcol = $PROJPLOTCOLS[$disppos];
				my $answered = $DISPANSWERED[$disppos];
				my $ptone    = $DISPPRESSONE[$disppos];

				next unless defined($proj->{$disp}{$Agent});

				$proj->{'PlotData'}{'Dial'} += $proj->{$disp}{$Agent} unless $disp eq 'AS';
				$proj->{'PlotData'}{$pplotcol} += $proj->{$disp}{$Agent} unless $disp eq 'AS';

				$reprows{$Agent}{'RE_Calls'} += $proj->{$disp}{$Agent} unless $disp eq 'AS';

				$reprows{$Agent}{$repcol} += $proj->{$disp}{$Agent} if $repcol ne 'na';
				if ($answered == 1) {
					$reprows{$Agent}{'RE_Answered'} += $proj->{$disp}{$Agent};
				}
				if ($ptone == 1) {
					$reprows{$Agent}{'RE_Pressedtone'} += $proj->{$disp}{$Agent};
				}
			}

			# histogram fields
			for my $histo (qw( 15_over_minutes 10_15_minutes 5_10_minutes 3_5_minutes 2_3_minutes 1_2_minutes 30_59_seconds 15_29_seconds 0_14_seconds )) {
				if (defined($proj->{$histo}{$Agent})) {
					$reprows{$Agent}{"RE_$histo"} = $proj->{$histo}{$Agent};
				} else {
					$reprows{$Agent}{"RE_$histo"} = 0;
				}
			}
				
				
			flog('DEBUG', "CO_RoundedDuration=" . $proj->{'CO_RoundedDuration'}{$Agent} . 
							"  CO_RoundedIPDuration=" . $proj->{'CO_RoundedIPDuration'}{$Agent} .
							"  StandbyDuration=" . $proj->{'StandbyDuration'}{$Agent} .
							"  StandbyIPDuration=" . $proj->{'StandbyIPDuration'}{$Agent} .
							"  RS_RoundedDuration=" . $proj->{'RS_RoundedDuration'}{$Agent} . 
							"  RS_RoundedIPDuration=" . $proj->{'RS_RoundedIPDuration'}{$Agent});

			# customer billing
			my $cost = 0;
			if ($c->{'CO_Billingtype'} eq 'T') { # time based i.e. per-minute
				$cost = (($proj->{'CO_RoundedDuration'}{$Agent} + $proj->{'StandbyDuration'}{$Agent}) * $c->{'CO_Rate'})/60 +
						(($proj->{'CO_RoundedIPDuration'}{$Agent} + $proj->{'StandbyIPDuration'}{$Agent}) * $c->{'CO_AgentIPRate'})/60;
			} elsif ($c->{'CO_Billingtype'} eq 'F') { # fixed per answered call
				$cost = $reprows{$Agent}{'RE_Answered'} * $c->{'CO_Rate'};
			} elsif ($c->{'CO_Billingtype'} eq 'C') { # fixed per agent connect
				if ($Agent ne '9999') {
					$cost = $reprows{$Agent}{'RE_Answered'} * $c->{'CO_Rate'};
				}
			} elsif ($c->{'CO_Billingtype'} eq 'A') { # fixed per call
				$cost = $reprows{$Agent}{'RE_Calls'} * $c->{'CO_Rate'};
			}
			$reprows{$Agent}{'RE_Tot_cost'} += $cost; # for this report line
			$c->{'Cost'} += $cost;
			flog('DEBUG',"Customer Billed Amount: $cost");

			# reseller billing
			if ($c->{'CO_ResNumber'} > 1) {
				my $r = $resellers{$c->{'CO_ResNumber'}};
				$cost = (($proj->{'RS_RoundedDuration'}{$Agent} + $proj->{'StandbyDuration'}{$Agent}) * $r->{'RS_Rate'})/60 +
						(($proj->{'RS_RoundedIPDuration'}{$Agent} + $proj->{'StandbyIPDuration'}{$Agent}) * $r->{'RS_AgentIPRate'}) /60;
				$r->{'Cost'} += $cost;
				$reprows{$Agent}{'RE_Res_Tot_cost'} += $cost; # for this report line
				flog('DEBUG',"Reseller " . $c->{'CO_ResNumber'} . " Billed Amount: $cost (using RS_Rate=" .
					$r->{'RS_Rate'} . " and RS_AgentIPRate=" . $r->{'RS_AgentIPRate'} . ")");
			}

			$reprows{$Agent}{'RE_Res_Sec'} += $proj->{'RS_RoundedDuration'}{$Agent} + $proj->{'RS_RoundedIPDuration'}{$Agent};
			$reprows{$Agent}{'RE_Tot_Sec'} += $proj->{'CO_RoundedDuration'}{$Agent} + $proj->{'CO_RoundedIPDuration'}{$Agent};
			$reprows{$Agent}{'RE_Tot_Live_Sec'} += $proj->{'CO_RoundedDuration'}{$Agent} - $proj->{'MachineDuration'}{$Agent};
			$reprows{$Agent}{'RE_Tot_Mach_Sec'} += $proj->{'MachineDuration'}{$Agent};
			$reprows{$Agent}{'RE_AS_Seconds'} += $proj->{'StandbyDuration'}{$Agent} + $proj->{'StandbyIPDuration'}{$Agent};

			# update the report
			my $check = "RE_Agent:$Agent\nRE_Calls:" . $reprows{$Agent}{'RE_Calls'} . "\n"; # for testing
			$sql = 'update report set RE_Calls = RE_Calls + ' . $reprows{$Agent}{'RE_Calls'}; # first one has no comma prepended
			my $inscols = 'RE_Project, RE_Agent, RE_Date, RE_Calls, RE_Customer';
			my $insvals = $proj->{'PJ_Number'} . ",$Agent,'" . $nowdt->ymd() . "', " .
						$reprows{$Agent}{'RE_Calls'} . ", " .
						$c->{'CO_Number'};

			for my $col (keys %{$reprows{$Agent}}) {
				if (($col ne 'RE_Calls') && ($reprows{$Agent}{$col} > 0)) {
					$sql .= ", $col = $col + " . $reprows{$Agent}{$col};
					$check .= "$col:" . $reprows{$Agent}{$col} . "\n";
					$inscols .= ",$col";
					$insvals .= ',' . $reprows{$Agent}{$col};
				}
			}

			$sql .= ' where RE_Project = ' . $proj->{'PJ_Number'} .
				" and RE_Agent = $Agent and RE_Date = '" .
				$nowdt->ymd() . "'";
			my $aff = $dbh->do($sql);
			if ((! defined($aff)) || ($aff == 0)) {
				# if update fails try an insert
				$dbh->do("insert into report ($inscols) values ($insvals)");
			}

		} # end of foreach Agent

		# write cdrs
		my $fname = "/dialer/projects/_" . $proj->{'PJ_Number'} . 
			"/cdr/cdr-" . $nowdt->ymd . '.txt';
		if (open(CDR, '>>', $fname)) {
			print CDR $proj->{'CDR'};
			close(CDR);
		} else {
			flog('ERROR', "unable to open cdr file $fname : $!");
		}

		# write report plot data 
		$fname = "/dialer/www/fancy/projplot-" . $proj->{'PJ_Number'} . '.json';
		my $flotnow = time() * 1000;
		if (open(PLOT, '>>', $fname)) {
			print PLOT "[ $flotnow";
			# <Time>     2          3         4          5            6          7
			for my $k ('Dial', 'NonConnect', 'Live', 'Machine', 'Transfer', 'LostTransfer') {
				my $val = $proj->{'PlotData'}{$k};
				$val = 0 unless defined $proj->{'PlotData'}{$k};
				print PLOT ", $val";
			}
			print PLOT " ],\n";
			close(PLOT);
		} else {
			flog('ERROR', "unable to open plot file $fname : $!");
		}

		# manage the number files
		my $numfile = 'projectnumbers_' . $proj->{'PJ_Number'};
		$dbh->do("create temporary table crp_work (
							Num char(10), 
							CallResult char(2), 
							CallDT datetime, 
							Duration integer, 
							SurveyResults varchar(64),
							DoNotCall char(1) not null default 'N',
							Dialer char(4),
							SysInfo varchar(64),
							Agent integer) ENGINE = MEMORY");

		if (defined($proj->{'UsedNumber'})) {
			for my $used (@{$proj->{'UsedNumber'}}) {

				$dbh->do("insert into crp_work values 
					('" . $used->{'CalledNumber'} ."','" .
					 $used->{'DispositionCode'} . "','" .
					 $used->{'DateTime'} . "','" .
					 $used->{'ActualDuration'} . "','" .
					 $used->{'SurveyResults'} . "','" .
					 $used->{'DoNotCallFlag'} . "','" .
					 $used->{'DialerId'} . "','" .
					 $used->{'ExtraInfo'} . "', 9999)");
			}
		}

		if (defined($proj->{'BridgedNumber'})) {
			for my $bridged (@{$proj->{'BridgedNumber'}}) {
				my ($Num, $Agent) = (
					$bridged->{'RelatedNumber'},
					$bridged->{'AgentNumber'}
				);
				$dbh->do("update crp_work
					set Agent = '$Agent'
					where Num = '$Num'");

				# Note: if there is no record where Num=$Num there is 
				#       some other problem, because this means we have
				#		an agent CDR referring to a prospect without 
				#		also having the prospect CDR.
			}
		}

		if (defined($proj->{'NonConnectedNumber'})) {
			if (open NC, '>>', '/root/NonConnectedNumber.txt') {
				print NC $proj->{'NonConnectedNumber'};
				close NC;
			}
		}

		if (defined($proj->{'BadNumber'})) {
			if (open NC, '>>', '/root/BadNumber.txt') {
				print NC $proj->{'BadNumber'};
				close NC;
			}
		}

		# flag numbers for after-hours deletion
		$dbh->do("update $numfile, crp_work set
				PN_CallResult = CallResult,
				PN_Agent = Agent,
				PN_CallDT = CallDT,
				PN_Duration = Duration,
				PN_SurveyResults = SurveyResults,
				PN_DoNotCall = DoNotCall,
				PN_Dialer = Dialer,
				PN_SysInfo = SysInfo,
				PN_Status = 'X' 
				where PN_PhoneNumber = Num");

		$dbh->do("drop table crp_work");

		# update the project
		my $tcall = '';
		if ((defined($proj->{'TestCall'})) && ($proj->{'TestCall'} == 1)) {
			$tcall = ', PJ_Testcall = now()';
		}
		$dbh->do("update project set PJ_LastCall = now() $tcall
			where PJ_Number = " . $proj->{'PJ_Number'});

		flog('DEBUG', "]]]]] end amalgamated project: $pjid");

	}

	# update customers
	for my $ckey (%customers) {
		# customer DNC
		if (defined($customers{$ckey}->{'DoNotCall'})) {
			my $tot = DialerUtils::custdnc_add($ckey, $customers{$ckey}->{'DoNotCall'});
			flog('INFO', "$tot numbers added to dnc list of customer $ckey");
		}

		# only CO_Credit needs updating
		if ((defined($customers{$ckey}->{'Cost'})) && ($customers{$ckey}->{'Cost'} > 0)) {
			my $sql = 'update customer set CO_Credit = CO_Credit - ' .
				$customers{$ckey}->{'Cost'} . " where CO_Number = $ckey";
			# execute customer sql
			$dbh->do($sql);
		}
	}

	# update reseller
	for my $rkey (%resellers) {
		# only RS_Credit needs updating
		if ((defined($resellers{$rkey}->{'Cost'})) && 
			($resellers{$rkey}->{'Cost'} > 0) && ($rkey > 1)) {
			my $sql = 'update reseller set RS_Credit = RS_Credit - ' .
				$resellers{$rkey}->{'Cost'} . " where RS_Number = $rkey";
			# execute reseller sql
			$dbh->do($sql);
		}
	}

	# update switch
	for my $skey (%switches) {
		if ((defined($switches{$skey})) && 
			($switches{$skey} > 0)) {

			my $sql = 'update switch set ' .
					'SW_callsday = SW_callsday + ' . $switches{$skey} .
					', SW_callsuur = SW_callsuur + ' . $switches{$skey} .
					" where SW_ID ='$skey'";
			# execute switch sql
			$dbh->do($sql);
		}
	}

	if (open PLOT, '>>', '/dialer/www/fancy/cdr.graph.json') {
			#  0    1    2     3     4    5     6     7     8
		my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime();

		if ($hour > 7) {
			my $jnow = time() * 1000;
			print PLOT "[ $jnow, " . 
				$plots{Dials} . ', ' .
				$plots{AgentCalls} . ', ' .
				$plots{Connects} . ', ' .
				$plots{CarrierBusy} . " ],\n";
		}

		close PLOT;
	} else {
		warn "opening plot file failed: $!";
	}

	# process the stats
	block_lines($stats->{Line});
	print_status();
	
	if (length($anomalystr) > 0) {
		open ANOM, '>>', '/dialer/www/status/anomaly-log.txt' or die "opening anomaly log failed: $!";
		print ANOM $anomalystr;
		close ANOM;
	}
}

flog('INFO', "PID=$$ ------------------------------------------------- starts");

$stats->{Total}{Connects} = 0;
$stats->{Total}{ProspectCalls} = 0;
$stats->{Total}{Human} = 0;
$stats->{Total}{AgentCalls} = 0;
$stats->{Total}{DurationTotal} = 0;
$stats->{Total}{"LoopTime-1"} = 0;
$stats->{Total}{"LoopTime-2"} = 0;
$stats->{Total}{"LoopTime-3"} = 0;
$stats->{Total}{"LoopTime-4"} = 0;
$stats->{Total}{"LoopTime-Total"} = 0;

my $iterdur = 0;

while ($running == 1) {

	my $x = time() % 60; # current seconds
	if ($iterdur < 60) {
		# sleep until the second hand points to 45
		if ($x < 45) {
			$x = 45 - $x;
		} else {
			$x = 105 - $x;
		}
	} else {
		$x = 5;
	}
	flog('INFO', "Sleeping $x seconds");
	while (($running == 1) && ($x > 0)) {
		sleep 1;
		$x--;
	}

	last unless $running == 1;

	$startpoint = time();
	$trancount = 0;
	$anomalystr = '';
	$nowdt = DateTime->now(time_zone => 'America/New_York');
	flog('INFO', 'Iteration starts - ' . $nowdt->hms() . ' - ' . $nowdt->ymd);
	$dbh = DialerUtils::db_connect();

	do_queue();

	$dbh->disconnect;
	$iterdur = time() - $startpoint;

	flog('INFO', "Iteration ends ($trancount results in $iterdur seconds; " .
		sprintf('%0.1f', $iterdur > 0 ? $trancount / $iterdur : 0.0) .  "tps)");
}

flog('INFO', 'Closing log file and exiting');
close $LOG;
