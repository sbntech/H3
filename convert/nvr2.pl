#!/usr/bin/perl -w

use strict;
use POSIX;
use IO::Socket;
use Socket qw(IPPROTO_TCP TCP_NODELAY);
use IO::Select;
use Fcntl;
use Tie::RefHash;
use DBI;
use LWP;
use HTTP::Request::Common qw( GET POST );
use Time::Local;
use File::Temp qw( tempfile );
use lib '/dialer/www/perl';
use DialerUtils;
use Logger;

my $hostname =`hostname`;
$hostname=~s/[\n]$//;

my $epocht =timegm(localtime());

$|++; #unbuffered output to stdout
my $IpNumber = $ARGV[0];
my $CARRIER_ID = $ARGV[1];
my $ApacheHost = 'w0.sbndials.com';
$ApacheHost = $ARGV[2] if defined($ARGV[2]);


# logger setup --------------------------------------------
my $log = Logger->new("/var/log/nvr.$IpNumber.log");

my $useragent = LWP::UserAgent->new;

# typedef struct tag_SOCK_RLL_MSG
#       char PrTy[4]; // Should be "PrTy"
#       char DestTaskName[16];
#       char SourceTaskName[16];
#       char MsgString[128];
my $VOSLength=164;
my $VOStmplen=160;
my $VOSStruct="a4 a16 a16 a128";
my $VOSPort="2222";
my $DialerPort = "2222";
my $NUMBERS_CACHED_PER_LINE = 3;

#  typedef struct s_CDRRecord
#  {
#	int Time;
#	char Phonenum[15];
#	char Status;
#	int Elapsed
#	int Agent
#  };
#
my @array;
my %Numbers; # $Numbers{<PJ_Number>} = [ '9494542000', ... ];
my %inbuffer;
my %outbuffer;
my %VOSPACKETS;
my %URGENTPACKETS;
my %callback;
my %CALLBACKSOCKS; # keyed by dialer name e.g.  $CALLBACKSOCKS{'D001'}
my %Terminate;
my $Select;
my $VOSSERVER;
my $CLIENT;
my $DATA; #2 purposes
my $rv;

my $LastTimerCall = time();

my $sth;
my $sqlquery;
my $TOTLN;
my $AANTLNBZ;
my $aantvrij;
my (    $prty,
        $DestTaskName,
        $SourceTaskName,
        $data);

my $cdrBuffer = '';
my $cdrSendTime = 0;
my $lteller;

if ($IpNumber !~ /\d*\.\d*\.\d*\.\d*/) {
	$log->fatal("ARGV[0] for IpNumber = \"$IpNumber\" is invalid");
	die("ARGV[0] for IpNumber = \"$IpNumber\" is invalid");
}	
	
open(PID, ">", "/var/run/nvr-$IpNumber.pid");
print PID $$;
close(PID);
$log->info("starts on $IpNumber:$DialerPort with pid $$ (ApacheHost=$ApacheHost; CARRIER_ID=$CARRIER_ID)");
my $DBH = DialerUtils::db_connect();

##################################################
sub Sock2IP {
	# converts a socket handle to a valid ip address
	my $client = shift;
	my $remoteid;
	if ($remoteid = getpeername($client)) {
		(my $inport, my $inhost) = unpack_sockaddr_in($remoteid);
		return inet_ntoa($inhost);
	} else {
		$log->error("Couldn't identify client: $!");
		return("[Unknown]");
	}
}

####################################################
# nonblok
####################################################
sub NonBlock {
my $socket=shift;
my $flags;

        $flags=fcntl($socket, F_GETFL, 0)
                or warn "Can't get flags for socket: $!\n";
        fcntl($socket, F_SETFL, $flags | O_NONBLOCK)
                or warn "Can't make socket nonblocking: $1\n";
	setsockopt($socket, IPPROTO_TCP, TCP_NODELAY, 1);
};

sub fh2switch {
	my $in = shift;

	# look for an original connection first
	# keys to %callback are strings not sockets
	for my $S (keys %callback) {
		if ($in eq $S) {
			# use the callback then for dialer lookup
			$in = $callback{$S};
		}
	}

	for my $C (keys %CALLBACKSOCKS) {
		if ($in eq $CALLBACKSOCKS{$C}) {
			return $C;
		}
	}

	return "UNKN";

}

####################################################
# Clean up globals when Client goes poo poo
####################################################
sub CleanUp {
	my $client=shift;

	my $swid = fh2switch($client);
	$log->debug("Cleanup - called for $swid");
	$DBH->do("delete from line where ln_switch ='$swid'");
	$DBH->do("update switch set sw_status = 'E' where SW_ID = '$swid'");

	delete $inbuffer{$client}; 
	delete $outbuffer{$client}; 
	delete $VOSPACKETS{$client};
	delete $URGENTPACKETS{$client};
	$Select->remove($client);
	$log->info("Closed client $client from $swid\n");
	close $client;

	return if(!defined $callback{$client});
	$client=$callback{$client};
	$swid = fh2switch($client);

	delete $inbuffer{$client};
	delete $outbuffer{$client}; 
	delete $VOSPACKETS{$client};
	delete $URGENTPACKETS{$client};
	$Select->remove($client);
	$log->info("Closed callback client $client from $swid\n");
	close $client;
	delete $callback{$client};
}

####################################################
# Handle Signals
####################################################
$SIG{TERM} = \&Exit;# kill
$SIG{INT}  = \&Exit;# ctrl-c
sub Exit {
	my $client;
	my @clients;

	$log->info("Shutting down");
	@clients = $Select->can_write(1);
	for $client (@clients) {
		$log->info("Sending RESETSWITCH to " . Sock2IP($client));
		$client->send(pack($VOSStruct, "PrTy", "-tcpsend-", "-database-", "RESETSWITCH"));
	}
	
	# return unused numbers for ALL projects
	foreach my $pj (keys %Numbers) {
		ReturnNumbers($pj);
	}

	# flush cdrs
	$cdrSendTime = 0;
	flushCDRbuffer();

	foreach $client (keys %callback) {
		close($callback{$client});
	}

	close($VOSSERVER) if defined($VOSSERVER);

	$DBH->do("delete from line where ln_ipnumber = '$IpNumber'");
	$DBH->do("update switch set sw_status = 'E' where SW_databaseSRV = '$IpNumber'");

	$log->info("exit\n\n\n");
	$log->fin;
	exit;
}


####################################################
# Connect
# makes the callback connection to VOS server
####################################################
sub Connect {
	my $host = shift; 
	my $port = shift;

	my $csock = IO::Socket::INET->new(PeerAddr => $host, PeerPort => $port, LocalAddr => $IpNumber,
		Proto => 'tcp', Blocking => 0, ReuseAddr => 1) or $log->error("client socket failed: $!");

	$outbuffer{$csock} = "hello";
	return $csock;
};


####################################################
# Main
# Loop the Server
#
# typedef struct tag_SOCK_RLL_MSG
# 	char PrTy[4]; // Should be "PrTy"
#	char DestTaskName[16];
#	char SourceTaskName[16];
#	char MsgString[128];
####################################################

my $Result;

die "Port to listen on not specified" if(!$VOSPort);
$VOSSERVER=IO::Socket::INET->new(LocalAddr => $IpNumber, LocalPort => $VOSPort, ReuseAddr => 1,
		Listen => SOMAXCONN ) or die("Could't set up nvr server on $IpNumber:$VOSPort: $!");
tie %VOSPACKETS, 'Tie::RefHash';
tie %URGENTPACKETS, 'Tie::RefHash';
tie %Terminate, 'Tie::RefHash';
NonBlock($VOSSERVER);
$Select=IO::Select->new($VOSSERVER);
&UpdateDB("update switch set SW_IP = '0.0.0.0', 
	SW_Status = 'E', SW_lstmsg = current_timestamp(), SW_Start = current_timestamp(),
	SW_callsuur = 0 where SW_databaseSRV = '$IpNumber'");
&UpdateDB("delete from line where exists (select 'x' from switch where SW_databaseSRV = '$IpNumber' and sw_id = ln_switch) 
		or not exists (select 'x' from switch where SW_ID = ln_switch)");
$log->info("Ready");

while(1) {
	# read
	foreach $CLIENT ($Select->can_read(1)) {
		# new dialer connection
		if($CLIENT eq $VOSSERVER) {
			$CLIENT=$VOSSERVER->accept();
			$log->info("Dialer connection from " . Sock2IP($CLIENT) . 
				"(CLIENT=$CLIENT fileno=" . $CLIENT->fileno . ") Making return path to port $DialerPort...");
			$CLIENT->autoflush(1);                        
			if ($callback{$CLIENT} = Connect(Sock2IP($CLIENT), $DialerPort)) {
				NonBlock($CLIENT);
				$Select->add($CLIENT);
				$Select->add($callback{$CLIENT});
				$log->info("Callback made to " . Sock2IP($CLIENT) . 
					"(callback{CLIENT}=" . $callback{$CLIENT} . " fileno=" . $callback{$CLIENT}->fileno . ")");
			} else {
				$log->info("Failed!");
				CleanUp($CLIENT);
			}
			next;
		}

		# receive packets
		$rv=recv($CLIENT, $DATA, $VOSLength * 200, 0); # take 200 packets 200 * 164 = 32k
		unless(defined($rv) && length $DATA) {
			CleanUp($CLIENT);
			next;
		}
		my $dpos = 0;
		my $dlength = length $DATA;
		while (1) { # loop over the chunked packets
			$inbuffer{$CLIENT} .= substr($DATA, $dpos, $VOSLength);
			$dpos += $VOSLength;
			last if (length ($inbuffer{$CLIENT}) == 0);
			while($inbuffer{$CLIENT}=~s/.*?((PrTy|GTec).{$VOStmplen})//){
				my $pkt = $1;
				if ($pkt =~ /GETOUTLINE/) {
					push(@{$URGENTPACKETS{$CLIENT}},$pkt);
				}
				else {
					push(@{$VOSPACKETS{$CLIENT}},$pkt);
				}
			}
			last if ($dpos >= $dlength);
		}

	} # for can_read                	

	# urgent packets
	foreach $CLIENT (keys %URGENTPACKETS) {
		foreach $DATA (@{$URGENTPACKETS{$CLIENT}}) {
			$Result =&DoPacket($callback{$CLIENT}, $DATA);
			if ((defined $Result) && ($Result)) {			
				$outbuffer{$callback{$CLIENT}}.= $Result;
			}
		}
		delete $URGENTPACKETS{$CLIENT};
	}

	# non-urgent packets
	foreach $CLIENT (keys %VOSPACKETS) {
		# process part of the VOSPACKETS array
		my $qsize = scalar @{$VOSPACKETS{$CLIENT}};
		my $worksize = 10 + int($qsize / 10);
		$log->debug("qsize=$qsize worksize=$worksize") if $qsize > 500;

		foreach $DATA (splice @{$VOSPACKETS{$CLIENT}},0, $worksize) {
			$Result =&DoPacket($callback{$CLIENT}, $DATA);
			if ((defined $Result) && ($Result)) {			
				$outbuffer{$callback{$CLIENT}}.= $Result;
			}
		}
	}

	# send the outbuffers
	foreach $CLIENT ($Select->can_write(1)) {
		next unless exists $outbuffer{$CLIENT};

		while (1) {
			my $len = length($outbuffer{$CLIENT});
			if ($len == 0) {
				delete $outbuffer{$CLIENT};
				last;
			}

			# take a piece no bigger than 164 bytes off the front 
			my $part = 164;
			$part = $len if $len < 164;
			my $msg = substr($outbuffer{$CLIENT}, 0, $part);
			my $sbytes = send($CLIENT, $msg, 0);

			if ((defined($sbytes)) && ($sbytes > 0)) {
				substr($outbuffer{$CLIENT}, 0, $sbytes) = '';
			} else {
				$log->info("send error: $!") unless $! == POSIX::EWOULDBLOCK;
				last;
			}
		}
	} 

	foreach $CLIENT (keys %Terminate)
	{
		if(!$outbuffer{$CLIENT})
		{
			$log->info("Teminating conn. to ".Sock2IP($CLIENT)."\n");
			CleanUp($CLIENT);
			delete $Terminate{$CLIENT};
		};
	};
	
	flushCDRbuffer(); # if needed

	# Note: the rand below is here to make sure that the various
	# nvr instances run their timers at different times
	if (time() - $LastTimerCall >= (10 + int(rand(5)))) { # every 10-15 seconds
        Timer();
     	$LastTimerCall = time();
	}

};#end while(1);
exit;
#END PROGRAM

################################################################
#
# Query
#
################################################################
sub Query {
my $query=shift;
my %db;
my @fields;
my ($i,$fname,$fvalue);
	if(defined $sth) {
		undef($sth);
		};
        $sth=$DBH->prepare($query) || warn $DBH->errstr;
        $sth->execute || warn $DBH->errstr;
        my $cols=$sth->{NUM_OF_FIELDS};

        if(@fields = $sth->fetchrow) 
	{
                for ($i=0;$i<$cols;$i++) 
		{
                        $fvalue=$fields[$i];
                        if(!defined $fvalue) {$fvalue='';}
                        $fname=$sth->{NAME}->[$i];
                        $db{$fname} = $fvalue;
			#$log->info("Q: [$fname]=[$fvalue]\n");
                };
	};
return %db;
}; # End Query();

################################################################
#
# NextRecord
#
################################################################
sub NextRow 
{
	my %db;
	my @fields;
	my ($i,$fname,$fvalue);
	my $cols=$sth->{NUM_OF_FIELDS};

	if(@fields = $sth->fetchrow) 
	{
                for ($i=0;$i<$cols;$i++) 
		{
                        $fvalue=$fields[$i];
                        if(!defined $fvalue) {$fvalue='';}
                        $fname=$sth->{NAME}->[$i];
                        $db{$fname} = $fvalue;
                };
        }else{
#		return;
	};
return %db;
};

################################################################
#
# Update de Database
#
################################################################
sub UpdateDB {
	my $query = shift;
	my $sth;

	if(!($sth=$DBH->prepare($query))){
		$log->warn("failed prepare on $query: " . $DBH->errstr);
		return 0;
	}

	if(!$sth->execute) {
		$log->warn("failed execute on $query: " . $DBH->errstr);
		return 0;
	}

	if(!$sth->finish) {
		$log->warn("failed finish on $query: " . $DBH->errstr);
		return 0;
	}
	return 1;
};

##################################################
sub SendMsg {
my $ws=shift;
my $header=shift;
my $msg=shift;
my $taskfrom="-database-";
my $taskto="-tcpsend-";
my $ReturnPacket;
#Put the header (switch-board-line-task) in front
#$msg="$header;$msg";
$taskto=$header;
my $key;
if (length($msg) > 128 ){
	$log->info ("message to big [$msg]");
}
if (not $CALLBACKSOCKS{$ws}){
        $log->info("No switch found [$ws][$msg]");
        return 0;
}

$ReturnPacket=pack($VOSStruct, "PrTy", $taskto, $taskfrom, $msg);

	if($CALLBACKSOCKS{$ws}){
		$outbuffer{$CALLBACKSOCKS{$ws}}.=$ReturnPacket;
		return 1;
	}else{
		print STDERR "OUTBUFFER NOT FOUND\n";
		return 0;
	};
};

##################################################
sub Timer {

	# check for switch resets
	my $resets = $DBH->selectall_arrayref("select SW_ID from switch 
		where SW_databaseSRV='$IpNumber' and SW_Status = 'X'",
		{ Slice => {}});
	for my $sw_reset (@$resets) {
		my $swid = $sw_reset->{'SW_ID'};
		$log->info("RESETSWITCH sent to $swid");
		SendMsg($swid, "-tcpsend-","RESETSWITCH");
		$DBH->do("update switch set SW_Status = 'E' where SW_ID ='$swid'");
		$DBH->do("delete from line where ln_switch ='$swid'");
		CleanUp($CALLBACKSOCKS{$swid});
	}

	# handle ln_action
	my $lref = $DBH->selectall_arrayref(
			"select id, ln_action, ln_status, ln_info, ln_switch, ln_line 
			from line where ln_action > 0 and ln_ipnumber= '$IpNumber'",
			{ Slice => {}});

	for my $ln (@$lref) {

		my $id = $ln->{'id'};
		my $ln_action = $ln->{'ln_action'};
		my $ln_status = $ln->{'ln_status'};
		my $ln_switch = $ln->{'ln_switch'};
		my $ln_line = $ln->{'ln_line'};
		my $ln_info = $ln->{'ln_info'};
		my $updateClause = '';

		if ($ln_action eq "888888") { # block
			if (($ln_status ne 'D') && ($ln_status ne 'E')) {
				SendMsg($ln_switch, $ln_line, 'STOP;NOW;');    
				$updateClause = ", ln_status = 'B'";
			} 
		} elsif ($ln_action eq "999999") { # stop
			SendMsg($ln_switch, $ln_line, 'STOP;AFTER;');    
			$updateClause = ", ln_status = 'S'";
		} elsif ($ln_action eq "777777") { # testcall
			if (($ln_status ne 'U') && ($ln_status ne 'W') && ($ln_status ne 'S') && ($ln_status ne 'D')) {
				# can do a test call where ln_status in Free Open Blocked Error
				my ($PJ_Type, $PJ_Type2, $PJ_PhoneCallC, $PJ_OrigPhoneNr, $TestPhone, $PJ_Number, $X_Type) = split(';', $ln_info);
				my $msg;
				if ($X_Type eq 'S') {
					$msg = "T-SA;$PJ_Type;$PJ_Type2;$PJ_Number;$PJ_PhoneCallC;$PJ_OrigPhoneNr;$TestPhone;";
				} else {
					$msg = "TESTCALL;$PJ_Type;$PJ_Number;$TestPhone;$PJ_Type2;$PJ_PhoneCallC;$PJ_OrigPhoneNr;";
				}
				my $rc = SendMsg($ln_switch, $ln_line, $msg);
				if ($rc == 1) {
					$updateClause = ", ln_status = 'U', ln_PJ_Number = $PJ_Number";
				}
			}
		} else { # it is T-SA to start a project
			if ($ln_status eq 'F') {
				my $PJ_Number = $ln_action;
				my $NumberString = getNumbers($PJ_Number, 5);

				if ($NumberString ne "NONUMBER") {
					my ($PJ_Type, $PJ_Type2, $PJ_PhoneCallC, $PJ_OrigPhoneNr) = split(';', $ln_info);		
					$PJ_PhoneCallC = "" if (!$PJ_PhoneCallC);
					$PJ_OrigPhoneNr = "" if (!$PJ_OrigPhoneNr);

					my $rc = SendMsg($ln_switch, $ln_line, "T-SA;$PJ_Type;$PJ_Type2;$PJ_Number;$PJ_PhoneCallC;$PJ_OrigPhoneNr;$NumberString;");			
					if ($rc == 1) {
						$updateClause = ", ln_status = 'U', ln_PJ_Number = $PJ_Number";
					}
				}
			}
		}
		$DBH->do("update line set ln_action = 0, ln_info = '', ln_lastused = now()$updateClause where id = $id");        
	}

	# return the %Numbers cache for projects not running on this nvr
	my $prow = $DBH->selectall_arrayref(
		"SELECT ln_PJ_Number from line 
		where ln_PJ_Number <> '' and ln_ipnumber= '$IpNumber' 
		group by ln_PJ_Number", { Slice => {}});
	PJCACHE: foreach my $pjkey (keys %Numbers) {
		foreach my $row (@$prow) {
			if ($pjkey == $row->{'ln_PJ_Number'}) {
				next PJCACHE;
			}
		}
		ReturnNumbers($pjkey);
	}
}


##################################################
# Handle VOS packets
##################################################
sub DoPacket {
	my $result;
	my $function;
	my $ReturnPacket;
	my $mytime ;
	my $timediff;
	my %db;

	my $client = shift;
	($prty, $DestTaskName, $SourceTaskName, $data) = unpack($VOSStruct, shift);
	$DestTaskName=~s/\0//g;
	$SourceTaskName=~s/\0//g;

	if ($prty eq "PrTy" or $prty eq "GTec") {	
		
		$result="ERROR";
		$data=~s/\0//sg; #fixed tys, because C sends \0's
		@array=split(';', $data);
		$function = $array[1];

		if ($function eq "INITSWITCH") {
			$log->info("init switch from " . $array[2] . " (fileno=" .
				$client->fileno . "; CALLBACK=$client)");
			$CALLBACKSOCKS{$array[2]}=$client;
			$result="OK";
			my $swip = Sock2IP($client);
			%db = Query("select SW_Number from switch where SW_ID = '" . $array[2] ."'");
			if ($db{SW_Number}) {
				&UpdateDB("update switch set SW_IP = '$swip', 
					SW_Status = 'A', SW_lstmsg = current_timestamp(), SW_Start = current_timestamp(),
					SW_callsuur = 0, SW_databaseSRV = '$IpNumber' where SW_ID ='" . $array[2] .
					"' and SW_Number = " . $db{SW_Number} );
			} else {
				&UpdateDB("insert into switch
					(SW_IP, SW_Status, SW_ID, SW_lstmsg, SW_start, SW_callsday, SW_callsuur, SW_databaseSRV) values
					('$swip', 'A', '" . $array[2] . "', current_timestamp(), current_timestamp(), 0, 0, '$IpNumber')");
			}
			&UpdateDB("delete from line where ln_switch ='$array[2]'");
		}

		if($function eq "GETOUTLINE") {
		  	$result=&GetOutline(@array);
			};
		if($function eq "SETLINESTATUS") {
			$result=&LineSetStatus(@array);
			};
		if($function eq "CDR") {
			$result=&CDR(@array);
		} 
		if ($function eq "SAVEUN") { #Save unused numbers 						
			# [2]=project, [3]=numberstr, [4]=trunk, [5]=who
			SaveUnusedNumbers($array[2],$array[3]);
			$result = "";
		}; 
	};
	if($result eq "ERROR") {
		$log->info("Error in packet : source [$SourceTaskName] dest [$DestTaskName] data[$data]");
	};
	if(!$result eq "") {        
		#$ReturnPacket=pack($VOSStruct, "PrTy", $SourceTaskName, $DestTaskName, "$SourceTaskName;$result");
		$ReturnPacket=pack($VOSStruct, "PrTy", $SourceTaskName,"XXXX", "$result");
	};
return $ReturnPacket;
}; # End DoPacket

################################################################
sub GetOutline{	
	my $Proj      =$array[2]; 
	my $Task      =$array[3]; 
	my $Kanaal    =$array[4]; 
	my $PhoneNR   =$array[5]; 
	my $PhProspect=$array[6]; 
	my $lsinfo;
	my $lRet ;
	my %db   ;	
	my $switch;
	my @LNinf;
	my $sqlquery;
	my ($ln_switch, $ln_line);	

	@LNinf=split('-',$SourceTaskName);
	$switch=$LNinf[0];	# 2     Switch
	
	# which line should the dialer use?
	%db=Query("Select ln_line, ln_tasknumber, ln_channel, ln_dti, ln_status, id FROM
		line WHERE ln_switch ='$switch' and (ln_status ='F' or ln_status ='O') 
		and ln_action = 0 order by ln_status desc,ln_lastused limit 1");
	if (! defined($db{ln_channel})) {
		$log->info("GETOUTLINE project=$Proj from $switch: no available lines (PhProspect=$PhProspect)");
		return "P1NOLINE";
	}

	# connect the agent
	my $ag = DialerUtils::connect_agent($DBH, $Proj, $PhProspect);
	if (! defined($ag->{'AgentPhoneNumber'})) {
		$log->info("GETOUTLINE project=$Proj from $switch: no agents or callcenter to call! (PhProspect=$PhProspect)");
		return "P1NOAGENT;";		
	}
	my $agent = $ag->{'AgentId'};
	my $telnr = $ag->{'AgentPhoneNumber'};
	
	$log->debug("GETOUTLINE project=$Proj from $switch: told to call agent $agent at $telnr using line " . $db{ln_line} . " (PhProspect=$PhProspect, ProspectLine=$SourceTaskName)");
		
	# send msg to line
	$lsinfo="DIALLIVE;$Proj;$telnr;$Kanaal;$Task;$agent;$PhProspect;";

	SendMsg($switch, $db{ln_line}, $lsinfo);	
	# update agent line
	$sqlquery = "update line set ln_lastused = now(),
		ln_status = 'U', ln_AG_Number = $agent, ln_action=0, 
		ln_PJ_Number = $Proj, ln_info='$lsinfo' where ln_line='" . $db{ln_line} . "'";
	&UpdateDB($sqlquery);

	# update prospect line
	$sqlquery = "update line set ln_lastused=CURRENT_TIMESTAMP(), ln_status='U' where ln_line='$SourceTaskName'"; 	        
	&UpdateDB($sqlquery);
	
	#send p1 info back to line
	return "P1OK;$db{ln_dti};$db{ln_tasknumber};";		
}



################################################################
sub LineSetStatus {

	my %db;
	my @LNinf		; #Array met lineinfo
	my $voice		=$array[2];	# 5     Voice J/N
	my $dti			=$array[3];	# 6     DTI
	my $status		=$array[4];	# 8     Status
	my $soort		=$array[5];	# 9     Soort
	my $trunk		=$array[6];	# 10 - we ignore trunk as sent from the dialer
	my $priority	=$array[7];	# 11	Priority
	my $ltype    	=$array[8];	# 11	Type N Normal I Incomming !
	my $lreson    	=$array[9];	# 11	#Reden van line set status
	my $switch		;#=$array[2];# 2     Switch
	my $board		;#=$array[3];# 3     board
	my $channel		;#=$array[4];# 4     Channel
	my $task		;#=$array[7];# 7     Task Number
	my $query;

	if($status ne "E" and $status ne "B"){
		$lreson="";
	} else {
		$log->info("SetStatus: $SourceTaskName status=$status reason=$lreson");
	}

	@LNinf=split('-',$SourceTaskName);
	$switch			=$LNinf[0];	# 2     Switch
	$board			=$LNinf[1];	# 3     board
	$channel		=$LNinf[2];# 4     Channel
	$task			=$LNinf[3];# 7     Task Number

	# reserve free lines as "open"
	if ($status eq "F" and $channel <= 2) { # 3 per T1
		$status="O";
	}

	$query="SELECT ln_status,ln_AG_Number,ln_PJ_Number,ln_reson FROM line WHERE ln_line='$SourceTaskName'";	
	%db=Query($query);
	$query ="";
	if(!$db{ln_status}) {
		# new line need to do an insert
	 	$query = "INSERT INTO line (ln_line, ln_switch, ln_board, ln_channel, ln_status, ln_ipnumber, ln_tasknumber, ln_dti, ln_voice, ln_action, ln_trunk, ln_PJ_Number, ln_AG_Number, ln_priority,ln_reson,ln_lastused) values
 		('$SourceTaskName', '$switch', '$board', '$channel', '$status', '$IpNumber', '$task', '$dti', '$voice', '','$CARRIER_ID', 0, 0, '$priority','$lreson', now())";
	} else {
		# updating an existing line
		my $statusClause = '';
		if ($db{ln_status} ne "B") {
			# only change ln_status if previous status is not blocked
			$statusClause = "ln_status = '$status',";
		}
		if (($db{ln_status} eq 'E') && ($status ne 'E')) {
			$log->info("Setstatus: $SourceTaskName changing from E("
				. $db{ln_reson} . ") to $status");
		}

		if ($status eq "F" or $status eq "O" or $status eq "E" or $status eq "D") {
			# ln_action=0 because we want to clear any pending action, eg. stop
			$query = "UPDATE line SET $statusClause	ln_voice='$voice', 	ln_dti='$dti',
					  ln_tasknumber='$task',
					  ln_PJ_Number=0,
					  ln_trunk = '$CARRIER_ID',
					  ln_action=0,
					  ln_AG_Number=0,
					  ln_info='', 
					  ln_reson='$lreson',
					  ln_lastused=CURRENT_TIMESTAMP() 
					  WHERE ln_line='$SourceTaskName'";					
		} else { # Stop, Wait, Block or Used
			$log->info("Odd SetStatus sent: $SourceTaskName status=$status oldstatus=" . $db{ln_status});
		}
	}

	if ($query ne "") {
		if (! &UpdateDB($query)) {
			$log->info("Failed: $query");
		}
	}

	return "OK";
};

################################################################
sub flushCDRbuffer {
	# sends $cdrBuffer at *:*:40, that is 5 secs before processing

	my $now = time();
	return if ($cdrSendTime > $now);

	# set a new cdrSendTime
	my $x = $now % 60;
	if ($x < 40) {
		$x = 40 - $x;
	} else {
		$x = 100 - $x;
	}
	$cdrSendTime = $now + $x;

	my $cdrBytes = length($cdrBuffer);

	if ($cdrBytes > 10) {
		if ($IpNumber =~ /10\.9\.2/) {
			# local - direct write
			my ($fh, $filename) = tempfile("$IpNumber-$cdrBytes-XXXXXXXX", DIR => '/tmp');
			if (! defined($fh)) {
				$log->error("failed to create a temporary file for call results");
				return;
			}

			print $fh $cdrBuffer;
			close $fh;

			system("mv $filename /dialer/call-results-queue");
		} else {
			# remote - use http post
			my $request	= HTTP::Request->new('POST', "http://$ApacheHost/pg/CallResult");
			$request->content($cdrBuffer);

			my $response = $useragent->request($request);

			if (! $response->is_success ) {
				$log->error("Could not communicate with the CallResult service\n");
				return;
			}
		}
		
		$cdrBuffer = "";
		$log->debug("CallResults ($cdrBytes bytes) written");
	}
}

################################################################
sub CDR {

	# CDR;<campaign_type>;<agent_id>;<project_id>;<phone>;<return_code>;<call_duration>;<new_number_amount>;<trunk>;<call_setup_info>;<add_to_nodial|survey_result|prospect_phone>;
	my $lineinf =$SourceTaskName;
	my ($switch, $board, $channel, $ltask) = split('-',$SourceTaskName);

	my $type	=$array[2];
	my $agent	=$array[3];
	$agent = '9999' if ($agent eq '');
	my $project	=$array[4];
	my $calledNumber=$array[5]; 
	$calledNumber = substr($calledNumber,1) if ((substr($calledNumber,0,1) ==1) && (length($calledNumber) > 10));
	my $disposition	=$array[6];
	my $duration	=$array[7];
	my $NewNumber	=$array[8];
	$NewNumber = 0 if ($NewNumber eq "" );
	my $ln_trunk    =$array[9]; 
	my $CallSetup   =$array[10];  
	my $AddToNodial =$array[11]; 
	my $SurveyResult = $array[12]; 
	my $ProspectPhonenumber = $array[13]; 
	$SurveyResult = '' unless defined($SurveyResult);
	$ProspectPhonenumber = '' unless defined($ProspectPhonenumber);

	# add a line to the big cdrBuffer
	my $DNCflag = 'N';
	$DNCflag = 'Y' if ((defined($AddToNodial)) && ($AddToNodial eq '1'));
	$cdrBuffer .= "$project," . time() . ",$calledNumber,$DNCflag,$duration,$disposition,$switch,$board-$channel-$ltask,$CallSetup,$ProspectPhonenumber,$SurveyResult,$agent\n";

	# agent disconnected?
	if ((defined($agent)) && ($agent != 9999)) {
		DialerUtils::disconnect_agent($DBH, $project, $agent);
		$log->debug("Project $project: Call to agent $agent ($calledNumber) on $SourceTaskName with prospect at $ProspectPhonenumber finished ($disposition)");
	}

	# $result holds the return string
	my $result = "";

	#Get some new numbers 
	if ($NewNumber > 0 ){
		my $h = $DBH->selectrow_hashref("select ln_pj_number, ln_status
			from line where ln_line ='$switch-$board-$channel-$ltask'");
		if ((defined($h->{'ln_pj_number'})) && ($h->{'ln_pj_number'} eq $project) 
			&& ($h->{'ln_status'} ne 'B') && ($h->{'ln_status'} ne 'E')) {
			$result = getNumbers($project,$NewNumber);
			if ($result eq "NONUMBER" ){		
				$result ="STOP;AFTER;NONUMBER";		
			} else {  		      
				$result = "NNB;$project;$result" ;
			}
		} else {
			$result = "NNB;$project;PROJECTFAULT";
		}
	}

	return $result;
}

################################################################
sub SaveUnusedNumbers {
	my $project = shift;
	my $numberstr = shift;

	chomp($numberstr);
	push @{$Numbers{$project}}, split(/:/, $numberstr);
}

################################################################
sub ReturnNumbers {
	my $project = shift;
	my $numstr = "";

	my $sz = scalar(@{$Numbers{$project}});

	if ($sz > 0) {
		my ($rcount, $rmiss, $elapsed) =
			DialerUtils::dialnumbers_put($DBH, $project, $Numbers{$project});
		$log->debug("numcache: Project $project: cachesize=$sz, numbers returned count=$rcount, rmiss=$rmiss in $elapsed seconds");
	} else {
		$log->debug("numcache: Project $project: cachesize=$sz, dialnumbers_put not called");
	}
	delete $Numbers{$project};
}

################################################################
sub LogToFile {
	my $lfile = shift;
	my $lmsg = shift;
	open(FILE,">>$lfile") || $log->error("Cannot write: $!");
	print FILE "$lmsg\n";
	close(FILE);
}


################################################################
sub GetLines {
my $amount=shift;
my $agent=shift;
my %db;
my $key;

	if(!$amount){
		return undef;
		};	
		%db=Query("SELECT ln_switch,COUNT(id) AS cnt FROM line WHERE ln_ipnumber= '$IpNumber' and ln_action = 0 and (ln_status='F' or ln_status='O')  GROUP BY ln_switch");
		if  ($db{cnt}) {
	  	  $log->info("First is: $db{cnt}\nAND: $amount\n");
	  while($db{cnt}<$amount)
	  {
		$log->info("$db{cnt} lines on switch [$db{ln_switch}]\n");
		%db=NextRow();
		if(!$db{ln_switch})
		{
			$log->info("No lines found!\n");
			return -1;
		};
	  };
	  $log->info("Found enough lines on $db{ln_switch}\n");
	  $amount--;
	  return $db{ln_switch};
        } else {
            $log->info("No lines found!\n");
            return -1;

        }
	return $db{ln_switch};
};

##############
sub getNumbers {
	my $project = shift;
	my $amount  = shift;

	# Returns: a string of numbers separated by ':' 
	# or "NONUMBER"
	
	# check if %Numbers need topping-up
	my $have = 0; 
	if (defined($Numbers{$project})) {
		$have = scalar(@{$Numbers{$project}});
	} else {
		$Numbers{$project} = [];
	}

	if ($have < $amount) {
		# fetch more numbers
		my ($actual, $elapsed) = DialerUtils::dialnumbers_get($DBH, $project, $CARRIER_ID, $amount, $Numbers{$project});
		$have = scalar(@{$Numbers{$project}});
		if (($elapsed > 0.05) || ($actual == 0)) {
			$log->debug("numcache: Project $project: $have numbers cached now (retrieved $actual more, in $elapsed seconds)");
		}
	}

	if ($have <= 0) {
		return "NONUMBER";
	}

	# retrieve numbers from %Numbers
	my $ret = "";
	for my $num (splice(@{$Numbers{$project}},0,$amount)) {
		$ret .= "$num:";
	}
	return $ret
}
