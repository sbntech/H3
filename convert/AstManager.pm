#!/usr/bin/perl

package AstManager;

use POSIX;
use IO::Socket::INET;
use Time::HiRes qw( gettimeofday tv_interval usleep );
use LWP;
use HTTP::Request::Common qw( GET POST );
use strict;
use warnings;

BEGIN {
	use Exporter   ();
	our @ISA = qw(Exporter);
	our @EXPORT = qw(%originations %channels &event_tostring);
}

our %originations; # {<actionid>}
our %gvar; # hash of global scalars
our %channels; # {<unique channel id>}
=pod
				 Id => sip channel used + timestamp,
				 RawDuration
				 BillableDuration
				 DispositionCode
				 States => {
				 	0 => { Desc => 'New', Timestamp = <ts> }
					5 => Ringing
					6 => Up (start of billing)
					9 => Hangup (end of billing)
				 Variables => hash ref
					 <varname> => { Value => <val>, Timestamp => <ts> }
					 HangupCause => cause code in the Hangup event 
					 HangupText => cause text in the Hangup event 
				 BridgedTo => channel id of the agent channel
=cut

sub load_AREACODE_STATE {
	my $self = shift;

	my $count = 0;
	open(TZFILE, '<', '/home/grant/H3/convert/npanxx-data/areacode-timezone.txt') 
		or die "Cannot open timezone file: $!";
	while (<TZFILE>) {
		if (/^(\d{3}) (\d*) (..) (.*)$/) {
			my ($areacode, $tz, $stcode, $desc) = ($1, $2, $3, $4);
			$self->{'AreaCode-State'}{$areacode} = $stcode;
			$count++;
		} else {
			chomp;
			$self->{'logger'}->warn("$_ not matched");
		}
	}
	close(TZFILE);
	$self->{'logger'}->info("$count areacodes loaded");

}

sub areacode2state {
	my $self = shift;
	my $ac = shift;
	my $st = $self->{'AreaCode-State'}{$ac};

	if (defined($st)) {
		return $st;
	} else {
		$self->{'logger'}->warn("WARNING: areacode $ac has no documented state");
		return 'XX';
	}
}

sub select_system_callerid {
	my $self = shift;
	my $number = shift;

	my @sysCallerIds = ('5712610012', '2406998981');

	# use one of the sysCallerIds (iterstate)
	for my $sysCID (@sysCallerIds) {
		if ($self->areacode2state(substr($sysCID,0,3)) ne
				$self->areacode2state(substr($number,0,3))) {
			$self->{'logger'}->debug("CALLER_ID: chose $sysCID (state=" . $self->areacode2state(substr($sysCID,0,3)) .
				") for number $number (state=" . $self->areacode2state(substr($number,0,3)) .
				")");
			return $sysCID;
		}
	}

	# last resort
	$self->{'logger'}->error("callerid of last resort used for $number");
	return $sysCallerIds[0];
}

sub prep_prospect_cdr {
	my $chan = shift;
	my $orig = shift;
	my $PJ_Type2 = shift;
	my $dialerId = shift;

	my $duration = 0;
	my $survey = '';
	my $DNCflag = 'N';
	my $disposition = 'EC';
	my $CarrierID = $orig->{'Carrier'};
	my $circuit = "C-$CarrierID";
	my $extra = 'NoChan';
	my $answeredBy = 'NoAnswer';
	my $testcallOK = 'TESTFAULT'; 
	my $CDRtime = time();
	my $connected = 'N';

	if (defined($chan)) {
		$disposition = $chan->{'DispositionCode'} if defined($chan->{'DispositionCode'});
		$duration = $chan->{'BillableDuration'} if defined($chan->{'BillableDuration'});
		$CDRtime = $chan->{'ResultTimestamp'} if defined($chan->{'ResultTimestamp'});
		$survey = $chan->{'SurveyResult'} if defined($chan->{'SurveyResult'});

		if (defined($chan->{'Variables'})) {

			if (defined($chan->{'Variables'}{'CustomerDNCRequest'})) {
				$DNCflag = 'Y';
			}

			if (defined($chan->{'Variables'}{'TestCallApproved'})) {
				$testcallOK = 'TESTOK';
			}

			$extra = 'HC';
			if (defined($chan->{'Variables'}{'HangupCause'})) {
				$extra .= $chan->{'Variables'}{'HangupCause'}{'Value'};
			} else {
				$extra .= 'x';
			}

			if (defined($chan->{'Variables'}{'AnsweredBy'})) {
				$answeredBy = $chan->{'Variables'}{'AnsweredBy'}{'Value'};
			}
		}
	}
	$extra .= "OR" . $orig->{'OriginateReason'} if defined($orig->{'OriginateReason'});

	if ($disposition eq 'OK') {
		if ($answeredBy ne 'NoAnswer') {
			if ($answeredBy eq 'Machine') {
				if ($PJ_Type2 eq 'L') {
					$disposition = 'MN';
				} else {
					$disposition = 'MA';
				}
			} elsif ($answeredBy eq 'TestCall') {
				$disposition = $testcallOK;
			} else {
				if ($duration > 20) {
					$disposition = 'HA';
				} else {
					$disposition = 'HU';
				}
			}
		} else {
			# a human hung up during detection
			$answeredBy = 'Undetected';
			$disposition = 'HU';
		}
	} elsif ($disposition eq 'CB') {
		$extra .= 'CB';
		$disposition = 'BU';
	}	

	my $cdr = {
				'PJ_Number' => $orig->{'PJ_Number'},
				'CDR_Time' => $CDRtime,
				'Called_Number' => $orig->{'PhoneNumber'},
				'DNC_Flag' => $DNCflag,
				'Duration' => $duration,
				'Disposition_Code' => $disposition,
				'Answered_By' => $answeredBy,
				'Dialer_Id' => $dialerId,
				'Circuit' => $circuit,
				'Extra_Info' => $extra,
				'Related_Number' => '', # no related number
				'Survey_Response' => $survey,
				'Agent_Number' => 9999 };
				
	return $cdr;
}

sub flush_cdrs {
	my $self = shift;
	my $host = shift;
	# sends $self->{'cdrbuffer'} 

	my $cdrBytes = length($self->{'cdrbuffer'});

	if ($cdrBytes > 10) {
		# remote - use http post
		my $request	= HTTP::Request->new('POST', "http://$host/pg/CallResult");
		$request->content($self->{'cdrbuffer'});

		my $response = $self->{'useragent'}->request($request);

		if (! $response->is_success ) {
			$self->{'logger'}->fatal("Could not communicate with the CallResult service\n");
			return;
		}
		
		$self->{'cdrbuffer'} = "";
		$self->{'logger'}->debug("CallResults ($cdrBytes bytes) posted to $host");
	}
}

sub append_cdr {
	my $self = shift;
	my $vh = shift; # hash of values
	# push CDR for posting (see CallResultProcessing.pl for CDR format)

	my $cdr = sprintf('%d,%s,%s,%s,%d,%s,%s,%s,%s,%s,%s,%d',
						$vh->{'PJ_Number'},
						$vh->{'CDR_Time'},
						$vh->{'Called_Number'},
						$vh->{'DNC_Flag'},
						$vh->{'Duration'},
						$vh->{'Disposition_Code'},
						$vh->{'Dialer_Id'},
						$vh->{'Circuit'},
						$vh->{'Extra_Info'},
						$vh->{'Related_Number'},
						$vh->{'Survey_Response'},
						$vh->{'Agent_Number'}) . "\n";

	$self->{'cdrbuffer'} .= $cdr;
	$self->{'logger'}->info("CDR: $cdr");
}
	
sub originate_action_id {
	my $self = shift;

	my $aid = int(rand(1000000));

	while (defined($originations{$aid})) {
		$aid = int(rand(1000000));
	}

	return $aid;	
}

sub find_origination_from_phnr {

	my $phnum = shift;

	my $orig;
	for my $aid (keys %originations) {
		if ($originations{$aid}{'PhoneNumber'} eq $phnum) {
			$orig = $originations{$aid};
			last;
		}
	}

	return $orig;

}

sub channels_tostring {
	my $chan = shift;
	my $desc = shift;

	my $str .= "---$desc channel : ";
	if (defined($chan)) {
		$str .= "$chan\n";
	} else { 
		$str .= "<undefined>\n";
		return $str;
	}

	my $c;
	for $c (sort keys %{$chan}) {
		next if ($c eq 'Variables') || ($c eq 'States');
		$str .= sprintf("   %20s => %s\n", $c, $chan->{$c});
	}

	$str .= "   ---variables:\n";
	for $c (sort keys %{$chan->{'Variables'}}) {
		$str .= sprintf("   %20s => %s (timestamp=%s)\n", $c, 
			$chan->{'Variables'}{$c}{'Value'},
			$chan->{'Variables'}{$c}{'Timestamp'});
	}

	$str .= "   ---states:\n";
	for $c (sort keys %{$chan->{'States'}}) {
		$str .= sprintf("   %20s \@ %s\n", 
			"$c (" . $chan->{'States'}{$c}{'Desc'} . ")", 
			$chan->{'States'}{$c}{'Timestamp'});
	}

	return $str;
}

sub dump_call {
	my $self = shift;
	my $actionid = shift;

	my $orig = $originations{$actionid};
	my $pchan; my $achan;
	if (defined($orig->{'ChannelId'})) {
		$pchan = $channels{$orig->{'ChannelId'}} if defined $channels{$orig->{'ChannelId'}};
		if (defined($pchan)) {
			$achan = $channels{$pchan->{'BridgedTo'}} if defined($pchan->{'BridgedTo'});
		}
	}

	my $str = "---origination ActionId=$actionid:\n";

	my $c;
	for $c (keys %{$orig}) {
		$str .= sprintf("   %20s => %s\n", $c, $orig->{$c});
	}

	if (defined($pchan)) {
		$str .= channels_tostring($pchan, 'orig');
	}

	if (defined($achan)) {
		$str .= channels_tostring($achan, 'bridged-to');
	}

	$self->{'logger'}->debug("origination dumper:\n$str");
}

sub originate_basic {

	# Timeout is used to determine if the call is stale/incomplete since the origination so must count ringtime etc.
	my $self = shift;
	my ($pjnum, $phone, $recref, $chan, $carrier, $variables, $exten, $priority, $context, $cid, $ringtime, $actionid, $timeout, $filler) = @_;

	if (!defined($recref)) {
		$self->{'logger'}->fatal("originate_basic called with undefined reference, skipping");
		return;
	}
	
	push @$variables, "OriginateActionId=$actionid";

	$self->send_action("Originate", {
			'Channel'	=> $chan,
			'Exten'		=> $exten,
			'Variable'	=> $variables, # array ref
			'Priority'	=> $priority,
			'Context'	=> $context,
			'CallerID'	=> $cid,
			'Timeout'	=> $ringtime * 1000, # how long to let it ring for 20k = 4 rings, 30k=5.5rings
			'Async'		=> 1
			}, { }, $actionid);

	# prepare a timestamp
	my ($secs, $msecs) = gettimeofday();
	my $now = sprintf("%d.%06d", $secs, $msecs);
	my ($ogap, $orate) = (0, 0);

	if (defined($gvar{'LastOriginationTimestamp'})) {
		my $last = $gvar{'LastOriginationTimestamp'};
		$ogap = sprintf('%0.3f', $now - $last);
		$orate = sprintf('%0.1f', 1 / ($now - $last));		
	}

	$gvar{'LastOriginationTimestamp'} = $now;

	$originations{$actionid} = {
		'SentTime' => $now,
		'Timeout' => $timeout,
		'Carrier' => $carrier,
		'CalledTo' => $chan,
		'PJ_Number' => $pjnum,
		'PhoneNumber' => $phone,
		'Reference' => $recref
	};

	my $msg = "Originate on project $pjnum [phone=$phone]: SentTime=$now, ActionId=$actionid to $chan (cid=$cid) into dialplan at $exten:$priority:$context, ringtime=$ringtime, timeout=$timeout, ref=$recref, ogap=$ogap, orate=$orate and variables: ";
	for my $var (@$variables) {
		$msg .= "$var  ";
	}

	$self->{'logger'}->debug($msg);
}

sub flushsendbuffer {
	my $self = shift;

	return unless defined($self->{'sendbuffer'});
	return unless length($self->{'sendbuffer'}) > 0;

	my $sbytes;
	eval {
		$sbytes = $self->{'sock'}->send($self->{'sendbuffer'});
	};
	if ($@) {
		warn "send died (lost conn?): $@";
	} else {
		if ((defined($sbytes)) && ($sbytes > 0)) {
			substr($self->{'sendbuffer'}, 0, $sbytes) = '';
		} else {
			warn("send error: $!") unless $! == POSIX::EWOULDBLOCK;
		}
	}
}

sub check_limits {

	# sanity checks
	my $ulimit = `/bin/bash -c 'ulimit -n'`;
	$ulimit = 1*$ulimit;
	die "FATAL: open file handles ulimit is too low ($ulimit) consider 'ulimit -n 64000'" unless ($ulimit > 20000);
	
=pod
Add the following two lines to /etc/security/limits.conf

* soft nofile 65535
* hard nofile 65535
root soft nofile 65535
root hard nofile 65535
=cut
}

sub send_action {
	my $self = shift;
	my $action = shift;
	my $pkt = shift;
	my $expect = shift;
	my $id = shift;
	$id = int(rand(1000000)) unless defined($id);

	my $msg = "Action: $action\r\nActionID: $id\r\n";
	for my $k (keys %$pkt) {
		if (!defined($pkt->{$k})) {
			warn("ERROR: $k is undefined in action $action with ActionID = $id");
		} else {
			if (ref($pkt->{$k}) eq 'ARRAY') {
				for my $v (@{$pkt->{$k}}) {
					$msg .= "$k: " . $v . "\r\n";
				}
			} else {
				$msg .= "$k: " . $pkt->{$k} . "\r\n";
			}
		}
	}
	$msg .= "\r\n";

	if ($action eq 'DBPut') {
		warn("INFO: Action $action with id=$id sent to asterisk (" . $pkt->{'Key'} . "=" . $pkt->{'Val'} . ")");
	}

	$self->{'sendbuffer'} .= $msg;
	$self->flushsendbuffer();
	$self->{'responses'}->{$id} = $expect;
	return $id;
}

sub newchannel_handler {
	my $self = shift;
	my $event = shift;

	if (length($event->{'channel'}) < 5) {
		# blank channel means origination failure, usually
		return;
	}

	my $chanId = $event->{'uniqueid'};

	$channels{$chanId}->{'Id'} = $chanId;
	$channels{$chanId}->{'RawDuration'} = 0;
	$channels{$chanId}->{'BillableDuration'} = 0;
	$channels{$chanId}{'States'}{'0'} = { 'Desc' => 'New', 'Timestamp' => $event->{'timestamp'} };
	
	$self->{'logger'}->debug("NewChannel $chanId for " . $event->{'channel'} . ' stored');
}

sub hangup_handler {
	my $self = shift;
	my $event = shift;

	my $chanId = $event->{'uniqueid'};
	my $c = $channels{$chanId};
	if (defined($c)) {
		$c->{'Variables'}{'HangupCause'} = 
			{ 'Value' => $event->{'cause'}, 'Timestamp' => $event->{'timestamp'}};
		$c->{'Variables'}{'HangupText'}	= 
			{ 'Value' => $event->{'cause-txt'}, 'Timestamp' => $event->{'timestamp'}};
		$c->{'States'}{'9'} = 
			{ 'Desc' => 'Hangup', 'Timestamp' => $event->{'timestamp'} };
		$self->{'logger'}->debug("Hangup on channel $chanId with cause=" . $event->{'cause'} . "-" . $event->{'cause-txt'});

	} else {
		$self->{'logger'}->debug("Hangup on unknown channel " .  $event->{'channel'} .
			" with cause=" . $event->{'cause'} . "-" . $event->{'cause-txt'});
	}
}


sub varset_handler {
	my $self = shift;
	my $event = shift;

	my $chanId = $event->{'uniqueid'};

	if ($chanId eq 'none::none') {
		# global variable like when dialplan is reloaded
		$self->{'logger'}->debug("VarSet (global) ignored: " .
			$event->{'variable'} . "=" . $event->{'value'});
		return;
	}

	if ((! defined($event->{'variable'})) || (! defined($event->{'value'}))) {
		$self->{'logger'}->warn("varset event without a variable/value:\n" 
			. event_tostring($event));
		return;
	}

	my ($var, $val, $ts) = ($event->{'variable'}, $event->{'value'}, $event->{'timestamp'});

	return if (substr($var,0,6) eq 'MACRO_');

	if (! defined($channels{$chanId})) {
		$self->{'logger'}->warn("varset event on an unrecognized channel $chanId");

		# Although the channel{$chanId} should exist already we do this
		# in case we somehow "missed" the newchannel event
		$channels{$chanId}->{'Id'} = $chanId;
		$channels{$chanId}->{'RawDuration'} = 0;
		$channels{$chanId}->{'BillableDuration'} = 0;
		if (! defined($channels{$chanId}{'States'}{'0'}{'Timestamp'})) {
			$channels{$chanId}{'States'}{'0'} = 
				{ 'Desc' => 'New', 'Timestamp' => $event->{'timestamp'} };
		}
	}

	my $amsg = '';
	if (defined($channels{$chanId}{'Variables'}{$var})) {
		$amsg = "[previously " . $channels{$chanId}{'Variables'}{$var}{'Value'} .
			"set at " . $channels{$chanId}{'Variables'}{$var}{'Timestamp'} . "]";
	}
		
	$channels{$chanId}{'Variables'}{$var} = { 'Value' => $val, 'Timestamp' => $ts };

	if ($var eq 'OriginateActionId') { 
		my $o = $originations{$val};

		if (defined($o)) {
			$o->{'ChannelId'} = $chanId; # linked the channel to the origination
			# channel already linked when we stored the value in Variables
			$amsg .= "[linked channel $chanId to origination action $val]";
		} else {
			$self->{'logger'}->error("$var=$val but not origination found for $val!");
		}
	} elsif ($var eq 'SurveyResult') {
		# concat this instead of replace
		if (defined($channels{$chanId}->{'SurveyResult'})) {
			$channels{$chanId}->{'SurveyResult'} .= $val;
		} else {
			$channels{$chanId}->{'SurveyResult'} = $val;
		}
	}

	# $self->{'logger'}->debug("VarSet on channel $chanId at $ts: $var = $val $amsg");

}

sub newstate_handler {
	my $self = shift;
	my $event = shift;

	my $chanId = $event->{'uniqueid'};

	if ((! defined($event->{'channelstate'})) || (! defined($event->{'timestamp'}))) {
		$self->{'logger'}->warn("newstate event without a channelstate/timestamp:\n" 
			. event_tostring($event));
		return;
	}

	if (! defined($channels{$chanId})) {
		$self->{'logger'}->warn("newstate event on an unrecognized channel $chanId");
		return;
	}

	my ($st, $std, $ts) = ($event->{'channelstate'}, $event->{'channelstatedesc'}, $event->{'timestamp'});
	my $amsg = '';
	if (defined($channels{$chanId}{'States'}{$st})) {
		$amsg = "[previously " . $channels{$chanId}{'States'}{$st}{'Timestampt'} .
			"state at " . $channels{$chanId}{'States'}{$st}{'Timestamp'} . "]";
	}
		
	$channels{$chanId}{'States'}{$st} = { 'Desc' => $std, 'Timestamp' => $ts };

	$self->{'logger'}->debug("newstate on channel $chanId at $ts: $st.$std $amsg");
}

sub originateresponse_handler {
	# called when the event: OriginateResponse comes in
	my $self = shift;
	my $event = shift;

	my $chanId = $event->{'uniqueid'};

	if (! defined($event->{'actionid'})) {
		$self->{'logger'}->error("originateresponse event without an action id!");
		return;
	}

	$self->{'logger'}->debug("originateresponse event: ActionId=" . $event->{'actionid'} .
		", ChannelId=$chanId, Reason=" . $event->{'reason'});
	my $o = $originations{$event->{'actionid'}};

	if (defined($o)) {
		$o->{'OriginateReason'} = $event->{'reason'};
	} else {
		$self->{'logger'}->error("originateresponse event with unrecognized action id:\n"
			. event_tostring($event));
	}
}

sub lost_conn {
	my $self = shift;

	# TODO does this happen now that the database is fast?
	$self->{'logger'}->error("lost connection, attempting to reconnect");
	$self->connect();

	my ($secs, $msecs) = gettimeofday();
	my $now = sprintf("%d.%06d", $secs, $msecs);
	for my $aid (keys %originations) {
		$originations{$aid}{'LostConnection'} = $now;
	}

}

sub handle_events {
	my $self = shift;
	my $originate_function = shift;
	my $event_hooks = shift;

	my $buf = '';
	my $rc = $self->{'sock'}->recv($buf, 1025*1024, 0);
	if (! defined($rc)) {
		if ($! == POSIX::EWOULDBLOCK) {
			&$originate_function();
			usleep(10000); # 0.01 sec
			return;
		} else {
			if ($self->{'running'} == 3) {
				$self->{'logger'}->error("socket error: $!");
				$self->lost_conn();
			}
			return;
		}
	} else {
		if (length($buf) == 0) {
			close($self->{'sock'});
			# TODO survive a crash of asterisk
			$self->lost_conn();
			return;
		}
		$self->{'_raw'} .= $buf;
	}

	# read to line that starts ^Event
	RESPONSE: while (1) {
		# responses are separated by 2 bank lines
		my $i = index($self->{'_raw'}, "\r\n\r\n");
		last RESPONSE unless $i > 0;

		# pop off the first response
		my $r = substr($self->{'_raw'}, 0, $i + 4);
		$self->{'_raw'} = substr($self->{'_raw'}, $i + 4);
		my %event;
		while ($r =~ s/^([\w-]*): ?([^\r\n]*)[\n\r]*(.*)/$3/) {
			$event{lc($1)} = $2;
		}
		$event{'body'} = $r;

		# uncomment out the following line to see events
		$self->{'logger'}->debug(event_tostring(\%event));

		# call the handler
		if (defined($event{'event'})) { # not Responses
			my $lcevt = lc($event{'event'});
			if ($lcevt eq 'newchannel') {
			  	$self->newchannel_handler(\%event);
			} elsif ($lcevt eq 'hangup') {
			  	$self->hangup_handler(\%event);
			} elsif ($lcevt eq 'varset') {
			  	$self->varset_handler(\%event);
			} elsif ($lcevt eq 'newstate') {
			  	$self->newstate_handler(\%event);
			} elsif ($lcevt eq 'originateresponse') {
			  	$self->originateresponse_handler(\%event);
			} elsif ($lcevt eq 'shutdown') {
				$self->{'logger'}->info("shutdown event occurred - terminating");
				$self->{'running'} = 2;
			} elsif ($lcevt eq 'peerstatus') {
				$self->{'logger'}->debug(event_tostring(\%event));
			}

			# allow additional customer handling
			if (defined($event_hooks->{$lcevt})) {
				$event_hooks->{$lcevt}(\%event);
			} elsif (defined($event_hooks->{'DEFAULT'})) {
				$event_hooks->{'DEFAULT'}(\%event);
			}

		} elsif (defined($event{'response'})) {
			if (defined($event{'actionid'})) {
				my $o = $originations{$event{'actionid'}};
				if (defined($o)) {
					# this is an originate response
					# ... prepare a timestamp
					my ($secs, $msecs) = gettimeofday();
					my $now = sprintf("%d.%06d", $secs, $msecs);

					$o->{'ResponseTime'} = $now;
					$o->{'ResponseMessage'} = $event{'response'};
					$self->{'logger'}->debug("Originate ResponseTime=$now, ResponseMessage=" .
						$event{'response'} . ", ActionId=" . $event{'actionid'});
				}

				if (($event{'response'} ne 'Success') && ($event{'response'} ne 'Follows')) {
					if (defined($o)) {
						$self->{'logger'}->fatal("action " . $event{'action'} . " with actionid " .  $event{'actionid'} . 
								" failed [" . $event{'response'} . " ] : " . $event{'message'});

						# shutdown the dialer - only for failed originations
						# SetVar actions can fail if the agent dial event gets a congestion response
						$self->{'running'} = 2;
					} else {
						$self->{'logger'}->warn("action " . $event{'action'} . " with actionid " .  $event{'actionid'} . 
								" failed [" . $event{'response'} . " ] : " . $event{'message'});
					}
				}
			} else {
				$self->{'logger'}->error("response without an action id");
			}
		} else {
			$self->{'logger'}->error("protocol error - not an event or a response!");
		}

		# need to keep flushing
		$self->flushsendbuffer();

		&$originate_function();

	}
}

sub foreign_channels {
	my $self = shift;
	# check for channels that have been hungup for more than 300 secs and clear them

	for my $chan (keys %channels) {
		my ($secs, $msecs) = gettimeofday();
		my $now = sprintf("%d.%06d", $secs, $msecs);

		my $newTimestamp = $channels{$chan}{'States'}{'0'}{'Timestamp'};
		if (! defined($newTimestamp)) {
			$self->{'logger'}->warn("Channel $chan has no state=0, deleting it");
			delete $channels{$chan};
			next;
		}
		
		my $hangupTimestamp = $channels{$chan}{'States'}{'9'}{'Timestamp'};
		if (defined($hangupTimestamp)) {
			my $sinceHangup = $now - $hangupTimestamp;
			if ($sinceHangup > 120) {
				$self->{'logger'}->warn(
					"Channel $chan has been hungup for $sinceHangup seconds, deleting it"); 
				delete $channels{$chan};
				next;
			}
		}

		my $sinceNew = $now - $newTimestamp;

		if (defined($channels{$chan}->{'BridgedTo'})) {
			if ($sinceNew > 600) {
				$self->{'logger'}->info("Channel $chan (bridged to " . $channels{$chan}->{'BridgedTo'} .
					") exists for $sinceNew seconds now");
			}
		} else {
			if ($sinceNew > 500) {
				if (!defined($channels{$chan}{'Variables'}{'OriginateActionId'})) {
					$self->{'logger'}->warn("stale channel $chan abandoned");
					delete $channels{$chan};
				} else {
					$self->{'logger'}->info("Channel $chan exists for $sinceNew seconds");
				}
			}
		}
	}
}

sub determine_callresult {
	my ($chanId, $OriginateReason) = @_;
	
	return unless defined($chanId);
	my $chan = $channels{$chanId};
	return unless defined($chan);
=pod
		BA - bad number
		NA - no answer
		BU - user busy
		CB - carrier busy
		EC - error condition
		OK - connected
		UN - unknown (perhaps)

		http://www.voip-info.org/wiki/index.php?page=Asterisk+variable+hangupcause
		http://www.asterisk.org/doxygen/trunk/AstCauses.html
=cut

	my $CDRtime = time();
	if (defined($chan->{'States'}{'9'})) {
		$CDRtime = int($chan->{'States'}{'9'}{'Timestamp'});
	}

	my $disposition = 'UN';
	if ((defined($chan->{'RawDuration'})) && ($chan->{'RawDuration'} > 0)) {
		$disposition = 'OK';
	} else {
		if (defined($chan->{'Variables'}{'HangupCause'})) {
			my $HangupCause = $chan->{'Variables'}{'HangupCause'}{'Value'};
			if ($HangupCause == 0) { 
				if ($OriginateReason == 8) { 
					$disposition = 'CB';
				} else {
					$disposition = 'NA';
				}
			} elsif ($HangupCause == 1) { # Unallocated (unassigned) number
				if ($OriginateReason == 8) { #Congested / unavailable
					$disposition = 'CB';
				} else {
					$disposition = 'BA';
				}
			} elsif ($HangupCause == 3) { # No route to destination
				if ($OriginateReason == 8) { #Congested / unavailable
					$disposition = 'CB';
				} else {
					$disposition = 'BA';
				}
			} elsif ($HangupCause == 16) { 
				if ($OriginateReason == 8) {
					$disposition = 'EC';
				} else {
					$disposition = 'NA';
				}
			} elsif ($HangupCause == 17) { # User Busy
				$disposition = 'BU';
			} elsif ($HangupCause == 18) { # No user responding
				$disposition = 'NA';
			} elsif ($HangupCause == 19) { # User alerting, no answer
				$disposition = 'NA';
			} elsif ($HangupCause == 20) { # Subscriber not present
				$disposition = 'NA';
			} elsif ($HangupCause == 21) { # Call Rejected
				$disposition = 'BA';
			} elsif ($HangupCause == 34) { # No Circuit/Channel Available
				# carriers send this for BAD numbers too
				$disposition = 'CB';
			} elsif ($HangupCause == 38) { # Network out-of-order
				# can be used for Bad numbers too
				$disposition = 'CB';
			} elsif ($HangupCause == 27) { # Destination Out-of-Order
				$disposition = 'BA';
			} elsif ($HangupCause == 28) { # Invalid Number Format (address incomplete) 
				$disposition = 'BA';
			} elsif ($HangupCause == 29) { # Facility Rejected (SIP 501)
				$disposition = 'EC';
			} elsif ($HangupCause == 58) { # Bearer capability not presently available
				$disposition = 'EC';
			} elsif ($HangupCause == 102) { # Recovery on Timer Expired
				$disposition = 'EC';
			} elsif ($HangupCause == 127) { # Internetworking, unspecified 
				$disposition = 'EC';
			}
		} else {
			# there was no hangup
			my @rc;
			$rc[0] = 'BA';
			$rc[1] = 'BU'; # possible to CB also
			$rc[3] = 'BU';
			$rc[5] = 'BU';
			$rc[8] = 'CB';

			# OR=4 should have a HangupCause

			if (defined($rc[$OriginateReason])) {
				$disposition = $rc[$OriginateReason];
			} else {
				$disposition = 'EC';
			}

		}
	}

	$chan->{'DispositionCode'} = $disposition;
	$chan->{'ResultTimestamp'} = $CDRtime;
}

sub calculate_durations {
	my $self = shift;
	my $chanId = shift;
	# ... calculate channel durations
	
	return unless defined($chanId);

	my $chan = $channels{$chanId};
	return unless defined($chan);

	# factor covering the gap between our duration calc and the carrier's
	my $CARRFACTOR = 1.07; 
	
	$chan->{'RawDuration'} = 0;
	$chan->{'BillableDuration'} = 0;

	if ((defined($chan->{'States'}{'9'})) && (defined($chan->{'States'}{'6'}))) {
		$chan->{'RawDuration'} = $chan->{'States'}{'9'}{'Timestamp'} 
								- $chan->{'States'}{'6'}{'Timestamp'};

		if ($chan->{'RawDuration'} < 0) {
				$self->{'logger'}->error("negative duration on channel $chanId (repaired)");
				$chan->{'RawDuration'} = abs($chan->{'RawDuration'});
				if ($chan->{'RawDuration'} > 30) {
					$chan->{'RawDuration'} = 30;
				}
		}
			
		# +1 is there because partial seconds count as whole seconds
		$chan->{'BillableDuration'} = int($CARRFACTOR * $chan->{'RawDuration'}) + 1;
	}
}

sub is_channel_hungup {
	my $self = shift;
	my $chanId = shift;
	my $chan;
	my $sinceHangup = -1;

	if (defined($chanId)) {
		if (defined($channels{$chanId})) {
			$chan = $channels{$chanId};
			if (defined($chan->{'States'}{'9'}{'Timestamp'})) {
				$sinceHangup = int(time() - $chan->{'States'}{'9'}{'Timestamp'});
			}
		} else {
			$self->{'logger'}->error("Unknown channel id ($chanId)");
		}
	}

	return ($chan, $sinceHangup);
	
}

sub check_completions {
	my $self = shift;
	my $timeout_callback = shift;
	my $result_callback = shift;

	my ($secs, $msecs) = gettimeofday();
	my $now = sprintf("%d.%06d", $secs, $msecs);

	ORIGINATION: for my $aid (keys %originations) {

		my $orig = $originations{$aid};
		my $chanId = $orig->{'ChannelId'};
		my ($chan, $sinceHangup) = $self->is_channel_hungup($chanId);

		# anomaly correction
		if (($sinceHangup > 5) && (!defined($orig->{'OriginateReason'}))) {
			$self->{'logger'}->warn("no OriginateResponse event on a hangup channel actionid=$aid, " .
				"chanid=$chanId, CalledTo=" . $orig->{'CalledTo'});
			$orig->{'Anomaly'} = "Missing OriginateReason";
			$orig->{'OriginateReason'} = 4;
		}

		# check for stale/incomplete/timed-out originations 
		# (note: cold calling agent originations can last a very long time)
		if ($orig->{'Timeout'} > 0) {
			my $len = $now - $orig->{'SentTime'};
			if ($len > $orig->{'Timeout'}) {
				$self->{'logger'}->debug("origination (aid=$aid) timed out after $len seconds");
				if (defined($chan)) {
					if (!defined($chan->{'BridgedTo'})) {
						# long call - something went wrong!
						determine_callresult($chanId, $orig->{'OriginateReason'});

						$self->dump_call($aid);
						&{$timeout_callback}($aid, $orig, $chan);
						delete $originations{$aid};
						delete $channels{$chanId} if defined $chan;
					} else {
						if ($len > 1200) {
							$self->{'logger'}->debug("long origination ($len seconds) action=$aid chanId=$chanId with bridged channel " . $chan->{'BridgedTo'});
						}
					}
				} else {
					$self->{'logger'}->warn("Origination timed-out and no channel was " .
						"defined actionid=$aid, CalledTo=" . $orig->{'CalledTo'});
					$orig->{'Anomaly'} = "Origination timeout without channel";
					$orig->{'OriginateReason'} = 0;
				}
			}
		}

		next ORIGINATION unless defined($orig->{'OriginateReason'}); # no OriginateResponse event yet

		if ($orig->{'OriginateReason'} == 4) {
			# answered/connected
			if (!defined($chan)) {
				$self->{'logger'}->error("connection but undefined channel after OR4");
				delete $originations{$aid};
				next ORIGINATION;
			} 
			
			# determine if hangup yet ...
			next ORIGINATION unless $sinceHangup > 1;

		}

		$self->calculate_durations($chanId);
		$self->calculate_durations($chan->{'BridgedTo'});
		determine_callresult($chanId, $orig->{'OriginateReason'});
		determine_callresult($chan->{'BridgedTo'}, 5);

		$self->dump_call($aid);
		&{$result_callback}($aid, $orig, $chan);
		delete $originations{$aid};
		delete $channels{$chanId} if defined $chanId;
	}
}

sub handle_response {
	my $self = shift;
	my $respstr = shift;

	my @lines = split(/\r\n/, $respstr);
	my %vars;
	for (@lines) {
		/(\w*): (.*)$/;
		$vars{$1} = $2;
	}

	if (! defined($vars{'ActionID'})) {
		warn("Response without an ActionId was ignored:\n$respstr");
		return;
	}

	my $e = $self->{'responses'}->{$vars{'ActionID'}};
	if (! defined($e)) {
		warn("Unmatched response ignored:\n$respstr");
		return;
	}
	my $aid = $vars{'ActionID'};
		
	for my $k (keys %$e) { # expected
		if (! defined($vars{$k})) {
			warn("Expected a '$k' variable in the response ($aid) but none was found in:\n$respstr");
		} else {
			if ($e->{$k} ne $vars{$k}) {
				warn("Expected response variable '$k' to have value:\n[" . $e->{$k} . 
						"]\n but it had value\n[" . $vars{$k} . "]");
			}
		}
	}
	delete $self->{'responses'}->{$aid};
}

sub recv_responses {
	my $self = shift;

	# will block if nothing to recv
	my $buf;
	$self->{'sock'}->recv($buf, 1024*1024, 0);
	$self->{'_raw'} .= $buf;

	RESPONSE: while (1) {
		# responses are separated by 2 bank lines
		my $i = index($self->{'_raw'}, "\r\n\r\n");
		last RESPONSE unless $i > 0;

		# pop off the first response
		my $r = substr($self->{'_raw'}, 0, $i + 4);
		$self->{'_raw'} = substr($self->{'_raw'}, $i + 4);

		$self->handle_response($r);
	}
}

sub event_tostring {
	my $event = shift;

	my $str = '';

	if (defined($event->{'event'})) {
		$str .= "event ==> " . $event->{'event'} . ", ";
	} elsif (defined($event->{'response'})) {
		$str .= "response ==> " . $event->{'response'} . ", ";
	}

	for my $k (sort keys %$event) {
		next if ($k eq 'body') || ($k eq 'response') || ($k eq 'event');
		
		$str .= "$k=" . $event->{$k} . ", ";
	}

	if ((defined($event->{'body'})) && (length($event->{'body'}) > 2)) {
		$str .= "\n--- start body\n" . $event->{'body'} . "\n--- end body";
	}

	return $str;
}

sub connect {
	my $self = shift;

	# connect 
	$self->{'sock'} = IO::Socket::INET->new(
		PeerAddr => $self->{'ip'}, 
		PeerPort => 5038,
		Proto => 'tcp',
		Blocking => 1,  # see blocking call below
		ReuseAddr => 1);
	if ($self->{'sock'}) {
		$self->{'sock'}->autoflush(1);
	} else {
		warn("tcp connection to " . $self->{'ip'} . " failed: $!");
		return;
	}

	# read response
	my $buf;
	$self->{'sock'}->recv($buf, 1024, 0);
	die "failed to get the protocol reply: got [$buf] instead" if $buf !~ /^Asterisk Call Manager\/1.1\r$/;

	# make it non-blocking AFTER we have read the protocol header
	$self->{'sock'}->blocking(0);

	# login
	$self->send_action("login", {
		'Username'	=> $self->{'user'},
		'Secret'	=> $self->{'password'},
		'Events'	=> $self->{'events'} ? $self->{'events'} : 'off'
		},{
		'Response'	=> 'Success',
		'Message'	=> 'Authentication accepted'
		});
	$self->recv_responses();
}

sub new {
	shift;
	my $ah = {};
	$ah->{'user'} = shift;
	$ah->{'password'} = shift;
	$ah->{'ip'} = shift;
	$ah->{'events'} = shift;
	$ah->{'logger'} = shift;
	$ah->{'_raw'} = '';
	$ah->{'running'} = 3; 
	# 3 - normal running, 
	# 2 - got signal, 
	# 1 - waiting for all numbers to dial, 
	# 0 - stop
	$ah->{'cdrbuffer'} = ''; 
	$ah->{'useragent'} = LWP::UserAgent->new;

	bless $ah;
	$ah->connect();
	return $ah;
}

sub disconnect {
	my $self = shift;
	return unless ($self->{'sock'}->connected());
	$self->send_action("logoff", {}, {});
	$self->recv_responses();
	close($self->{'sock'});
}

1;
