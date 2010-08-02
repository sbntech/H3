#!/usr/bin/perl

use strict;
use warnings FATAL => 'all';

use lib '/home/grant/H3/www/perl';
use Logger;
use IO::Socket::INET;
use IO::Select;
use POSIX;
use Time::HiRes qw(usleep ualarm gettimeofday tv_interval);
my $pkt;
my $pktfmt = "a4 a16 a16 a128";
my %conf = (
    'max_lines' => 322,
    'carrier' => 'GMXX'
);

my @PDIST;
for ( 0 ..  9) { $PDIST[$_] = 'BA'; }
for (10 .. 19) { $PDIST[$_] = 'BU'; }
for (20 .. 29) { $PDIST[$_] = 'NA'; }
$PDIST[30] = 'EC';
for (31 .. 59) { $PDIST[$_] = 'HA'; }
for (60 .. 69) { $PDIST[$_] = 'HU'; }
for (70 .. 89) { $PDIST[$_] = 'MA'; }
for (90 .. 99) { $PDIST[$_] = 'MN'; }

# dnum: used to identify the dialer and assign the IP address as 127.0.0.$dnum
my ($dnum, $nvrAddr, $ip) = @ARGV;

my $dname = sprintf("D%03d", $dnum); # construct a dialer name

# logger setup ----------------------------------------------------------------
my $log = Logger->new("/var/log/nulldialer-$dname.log");

$log->debug("starts dnum=$dnum name=$dname ip=$ip");

# network init ----------------------------------------------------------------
my $sendbuf = "";
my $lsock = IO::Socket::INET->new(Listen => SOMAXCONN, LocalAddr => $ip, LocalPort => 2222,
    Proto => 'tcp', Blocking => 0, ReuseAddr => 1) or die("listening socket failed: $!");
my $csock = IO::Socket::INET->new(PeerAddr => $nvrAddr, PeerPort => 2222, LocalAddr => $ip, LocalPort => 2220,
    Proto => 'tcp', Blocking => 0, ReuseAddr => 1) or die("client socket failed: $!");

my $nsock;
my $wait = 10;
while ((! ($nsock = $lsock->accept())) and $wait > 0) {
        $log->info("Waiting for a reverse connection: $wait ($!)");
        sleep 1;
        $wait--;
}

die("accept() failed: $!") if ($wait == 0);
$log->debug("connections established");

$nsock->recv($pkt, length("hello"));
if ($pkt ne "hello") {
    die("handshake failed. did not receive a 'hello' got '$pkt' instead");
}
else {
    $log->debug("handshake completed");
}

my %projects;
my %tasks;

# subroutines -----------------------------------------------------------------
sub send_packet {
	$sendbuf .= shift if @_;

	while (1) {
		my $len = length($sendbuf);
		last if $len == 0;

		# take a piece no bigger than 164 bytes off the front 
		my $part = 164;
		$part = $len if $len < 164;
		my $msg = substr($sendbuf, 0, $part);

    	my $sb = $csock->send($msg);
		if ((defined($sb)) && ($sb >0)) {
			substr($sendbuf, 0, $sb) = '';
			$log->debug("sent: " . substr($msg,0,$sb));
		} else {
			if ($! == POSIX::EWOULDBLOCK) {
				sleep 1;
			} else {
				$log->info("send error: $!");
			}
			last;
		}
	}

}

sub source_task {
    my $L = shift;

    my $trunk = int($L / 23) + 1;
    my $chan = ($L % 23) + 1;

    return "$dname-$trunk-$chan-$L";
}

sub gen_cdrs {
	my $pjnum = shift;
	my $numlist = shift;
	my $dest = shift;

	$log->error("bad project $pjnum") unless defined $projects{$pjnum};
	my $p = $projects{$pjnum};

	my $morenumbers = 5;
	$morenumbers = "" unless defined($tasks{$dest}); # if we got a stop, don't ask for more
	for my $num (split(':', $numlist)) {
		send_packet(pack($pktfmt, "GTec", $dname, $dest, 
				';CDR;' . $p->{Type1} . ";9999;$pjnum;$num;HU;10;$morenumbers;" .
				$conf{carrier} . ";00;N;;;"));
		$morenumbers = "";
		$log->debug("cdr for $num sent from $dest");
	}
}

sub handle_packet {
    my $pkt = shift;

    # parse the packet
    my ($prty, $dest, $source, $data) = unpack($pktfmt, $pkt);
    $dest =~ s/\0//g;
    $source =~ s/\0//g;
    $data =~ s/\0//g;
    my @parts = split(';', $data);

	#$log->debug("handle_packet: dest=$dest source=$source data=$data");

    if ($parts[0] eq "OK") {
        $log->debug("OK for $dest");
	} elsif ($parts[0] eq "P1OK") {
        $log->debug("P1OK for $dest");
    } elsif ($parts[0] eq "TESTCALL") {
        $log->debug("starts processing TESTCALL message: $data");
        my ($func,$pjtype,$pjnum,$numdial,$pjtype2,$numagent,$cid) = @parts;
		if ($pjnum > 0) { # TESTCALLSWITCH sends project=0
	        send_packet(pack($pktfmt, "GTec", $dname, $dest, ";CDR;$pjtype;;$pjnum;$numdial;TESTOK;60;;" . $conf{carrier} . ";00;N;;;"));
		}
    	send_packet(pack($pktfmt, "GTec", $dname, $dest, ";SETLINESTATUS;Y;NDLR;F;x;" . 
				$conf{carrier} . ";5;N;Testcall"));
        $log->debug("finished processing TESTCALL - result sent from $dest");
    } elsif ($parts[0] eq "WAIT") {
        $log->debug("WAIT message: $data for $dest");
		$tasks{$dest}->{'Paused'} = (time + 10) if defined($tasks{$dest});
    } elsif ($parts[0] eq "START") {
        $log->debug("START message: $data for $dest");
		delete $tasks{$dest}->{'Paused'};
    } elsif ($parts[0] eq "STOP") {
        $log->debug("STOP message: $data for $dest");
        my ($func,$when,$more) = @parts;
		$tasks{$dest}->{'Stopped'} = 1 if defined($tasks{$dest});
		if ($when eq 'NOW') {
			my $numstr = '';
			map { $numstr .= "$_:"; } @{$tasks{$dest}->{'Numbers'}};
			if (length($numstr) > 0) {
	    		send_packet(pack($pktfmt, "GTec", $dname, $dest, ";SAVEUN;" .
					$tasks{$dest}->{'PJ_Number'} . ";$numstr;" .
					$conf{carrier} . ";$dname"));
			}
		}
		$log->debug("$more on $dest") if $more;
    } elsif ($parts[0] eq "DIALLIVE") {
        $log->debug("starts processing DIALLIVE message: $data");
        my ($func,$pjnum,$agentPh,$chan,$task,$agentId,$prospectPh) = @parts;
		$log->info("DIALLIVE response took: " . tv_interval($tasks{$task}->{'outlineTS'}));
		$tasks{$dest} = {
			'State' 		=> 'bridge',
			'AgentId'		=> $agentId,
			'AgentNumber'	=> $agentPh,
			'PJ_Number'		=> $pjnum,
			'ProspectTask' 	=> $task
		};
		$tasks{$task}->{'AgentTask'} = $dest;
		$tasks{$task}->{'State'} = 'wait';
		$log->debug("prospect on $task <---> agent (" . $agentId . ") on $dest");
    } elsif ($parts[0] eq "RESETSWITCH") {
        $log->debug("RESETSWITCH message ... exiting: $data");
		exit;
    } elsif ($parts[0] eq "NNB") {
        $log->debug("NNB message($dest): $data");
        my ($func,$pjnum,$numlist) = @parts;
		if ($numlist ne 'PROJECTFAULT') {
			if (defined($tasks{$dest})) {
				push(@{$tasks{$dest}->{'Numbers'}},split(':', $numlist));
				$tasks{$dest}->{'AskedForNumbers'} = 0;
			} else {
				$log->debug("NNB message after line $dest was stopped");
				# send the numbers back
	    		send_packet(pack($pktfmt, "GTec", $dname, $dest, 
						";SAVEUN;$pjnum;$numlist;" .
						$conf{carrier} . ";$dname"));
			}
		}
    } elsif ($parts[0] eq "T-SA") {
        $log->debug("T-SA message: $data");
        my ($func,$pjtype,$pjtype2,$pjnum,$callcenter,$callerid,$numlist) = @parts;
		$projects{$pjnum} = {Type1 => $pjtype, Type2 => $pjtype2, CallCenter => $callcenter, CallerId => $callerid};
		$tasks{$dest} = {
			'State' 	=> 'start',
			'PJ_Number'	=> $pjnum,
			'Numbers'	=> [split(':', $numlist)]
		};
    } else {
        $log->error("unhandled packet type received: $data for $dest from $source");
    }

}

sub liberate {
	my $tk = shift;
	send_packet(pack($pktfmt, "GTec", $dname, $tk, ";SETLINESTATUS;Y;NDLR;F;x;" . 
			$conf{carrier} . ";5;N;Liberated"));
	$log->debug("liberated $tk");
	delete($tasks{$tk});
}

sub send_cdr {
	my $kind = shift;
	my $ptk = shift;

	my $t = $tasks{$ptk};
	my $pjnum = $t->{'PJ_Number'} or die "no project";
	my $pj = $projects{$pjnum} or die "no project";

	my $morenumbers = "";
	if ((! $t->{'AskedForNumbers'}) && 
		((! defined($t->{'Stopped'})) || ($t->{'Stopped'} == 0)) && 
			(scalar(@{$t->{'Numbers'}}) <= 3)) {
		$morenumbers = "5";
		$t->{'AskedForNumbers'} = 1;
	}

	my $ph = $t->{'ProspectNumber'};
	my $dur = $t->{'ProspectDuration'};
	my $source = $ptk;
	my $bph = "";
	my $agentId = "9999";
	if ((substr($kind,0,1) eq 'A') || ($kind eq 'DA')) {
		my $a = $tasks{$t->{'AgentTask'}};
		$ph = $a->{'AgentNumber'};
		$agentId = $a->{'AgentId'};
		$dur = $t->{'AgentDuration'};
		$bph = $t->{'ProspectNumber'};
		$source = $t->{'AgentTask'};
	}

	my $extra = '00';
	if (($kind eq 'BU') && (rand() > 0.8)) {
		$extra = '0-556-0'; # carrier busy 20% of the time
	}

	my $dncflag = 'N';
	if (($kind eq 'HA') && (rand() > 0.9)) {
		$dncflag = '1'; # dnc 10% of the time
	}

	my $cdr = pack($pktfmt, "GTec", $dname, $source, ';CDR;' . $pj->{Type1} . 
		";$agentId;$pjnum;$ph;$kind;$dur;$morenumbers;" . $conf{carrier} . ";$extra;$dncflag;;$bph;");
	send_packet($cdr);
	$cdr =~ tr/\0/./;
	$log->debug("cdr: $cdr");
}


# initswitch ----------------------------------------------
send_packet(pack($pktfmt, "GTec", $dname, "$dname-0-0-0", ";INITSWITCH;$dname"));

# initial status ------------------------------------------
for (my $L = 0; $L < $conf{max_lines}; $L++) {
    my $src = source_task($L);
    send_packet(pack($pktfmt, "GTec", $dname, $src, ";SETLINESTATUS;Y;NDLR;F;x;" . $conf{carrier} . ";5;N;Initialize"));
}
$log->info($conf{max_lines} . " lines initialized");

# main loop -----------------------------------------------
my $iosel = IO::Select->new($csock, $nsock);
my $data;
my $buf = "";
my $pktsize = 164;
while (1) {
	# sned anything that might be in the buffer
	send_packet();

    # read what we can
    foreach my $sock ($iosel->can_read(1)) {
        # read a large block
        my $rc = $sock->recv($data, $pktsize * 20, 0);
        unless (defined($rc) && length($data) > 0) {
            die("lost the nvr: $!");
			exit;
        }
        $buf .= $data;
    }
	sleep 1 unless length($buf) > 0;

    # iterate through the packet buffer
    while($buf =~ s/.*?((PrTy|GTec).{160})//) {
        handle_packet($1);
    };

	# State machine for calling
	for my $tk (keys %tasks) {
		my $t = \%{$tasks{$tk}};
		if (!defined($t->{'State'})) {
			die("$tk has no state");
		}
		$log->debug($tk . ': State=' . $t->{'State'});

		# State == 'outline' : no op - moves when a DIALLIVE comes
		# State == 'bridge' : no op - moves when prospect line finishes
		if ($t->{'State'} eq 'start') {
			# 'start' may be useful in future
			$t->{'State'} = 'run';
		}
		if ($t->{'State'} eq 'wait') {
			if ($t->{'WaitUntil'} <= time) {
				# waiting is over
				$t->{'State'} = $t->{'PostWaitState'};
				delete($t->{'PostWaitState'});
				delete($t->{'WaitUntil'});
			}
		}
		if ($t->{'State'} eq 'run') {

			if (($t->{'Stopped'}) && (scalar(@{$t->{'Numbers'}}) == 0)) {
				liberate($tk);
			} elsif (scalar(@{$t->{'Numbers'}}) == 0) {
				# waiting for numbers ...
				$log->debug("$tk waiting for numbers to arrive");
			} elsif (defined($t->{'Paused'})) {
					# do nothing
					if ($t->{'Paused'} > time) {
						$log->debug("$tk still paused");
						$t->{'Paused'} = time + 10;
					}
			} else {
				# pick a disposition from the prospect distribution @PDIST
				my $disp = $PDIST[int(rand(100))];
				my $dur = int(13 + rand(30));
				$dur = 0 if grep(/$disp/, ('BA', 'BU', 'NA', 'EC'));

				$t->{'State'} = 'wait';
				$t->{'PostWaitState'} = $disp;
				$t->{'ProspectDuration'} = $dur;
				$t->{'WaitUntil'} = time + $t->{'ProspectDuration'};
				$t->{'ProspectNumber'} = shift(@{$t->{'Numbers'}});
				$log->debug("$disp call to " . $t->{'ProspectNumber'} . " started on $tk for " .
					$t->{'ProspectDuration'} . ' seconds');
			}
		}
		if ($t->{'State'} eq 'AC') {
			$log->debug("Agent call ended on $tk");
			send_cdr('HA', $tk);
			send_cdr('AC', $tk);

			$tasks{$t->{'AgentTask'}}->{'State'} = 'Final'; # removes the task with State == 'bridge'
			$t->{'State'} = 'run'; # process more numbers
			next;
		}
		if (($t->{'State'} eq 'BU') || ($t->{'State'} eq 'BA') 
			|| ($t->{'State'} eq 'NA') || ($t->{'State'} eq 'EC')
			|| ($t->{'State'} eq 'HU') || ($t->{'State'} eq 'EC')
			|| ($t->{'State'} eq 'MA') || ($t->{'State'} eq 'MN')) {
			$log->debug("Prospect call ended on $tk");
			send_cdr($t->{'State'}, $tk);
			$t->{'State'} = 'run'; # process more numbers
			next;
		}
		if ($t->{'State'} eq 'HA') {
			my $p1 = (rand(100) < 4);
			my $pjnum = $t->{'PJ_Number'} or die;
			my $pj = $projects{$pjnum} or die;

			if (($pj->{Type1} eq 'P') 
				&& ($p1) # TODO comment to prevent every HA being a P1
				) {
				# get out line
				$t->{'outlineTS'} = [gettimeofday];
				send_packet(pack($pktfmt, "GTec", $dname, $tk, 
					";GETOUTLINE;$pjnum;$tk;99;" . $pj->{'CallCenter'} . ';' .
					$t->{'ProspectNumber'} . ";"));
				$log->debug("GETOUTLINE for prospect on $tk");
				$t->{'State'} = 'outline';
				$t->{'PostWaitState'} = 'AC';
				$t->{'AgentDuration'} = int(23 + rand(30));
				$t->{'ProspectDuration'} += $t->{'AgentDuration'};
				$t->{'WaitUntil'} = time + $t->{'AgentDuration'};
			} else {
				if (rand() > 0.9) {
					# testing anomalie dropping in CallResultProcessing
					$t->{'ProspectDuration'} = 4000;
				}
				send_cdr('HA', $tk);
				$t->{'State'} = 'run';
			}
		}
		if ($t->{'State'} eq 'Final') {
			liberate($tk);
		}
	}

}

$log->debug("ends");
$log->fin;

