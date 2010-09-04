package DialerUtils;
use DBI;
use Carp;
use IO::Socket;
use Time::HiRes qw( gettimeofday tv_interval );

sub pretty_size {
	my $size = shift;

	my $szstr;
	if ($size < 1024) {
		$szstr = "${size} b";
	} elsif ($size < 1024*1024) {
		$szstr = int($size / 1024) . ' Kb';  
	} elsif ($size < 1024*1024*1024) {
		$szstr = sprintf('%0.1f Mb', $size / (1024 * 1024));  
	} else {
		$szstr = sprintf('%0.1f Gb', $size / (1024 * 1024 * 1024));  
	}
	
	return $szstr;
}

sub add_credit {
	# Adds credit to customers/resellers and logs it in table addcredit
	my $dbh = shift;
	my %parms = @_;
	my $aff = 0;
	my $ac_Col;

	if ((! defined($parms{'Mode'})) || 
	    (($parms{'Mode'} ne 'customer') && ($parms{'Mode'} ne 'reseller')) ) {
		return (undef, 'Invalid mode supplied, in add_credit');
	}

	if ((! defined($parms{'ac_user'})) || (length($parms{'ac_user'}) == 0)) {
		return (undef, 'No user name was supplied');
	}

	my $amount = DialerUtils::make_a_float($parms{'Amount'});
	my $id = DialerUtils::make_an_int($parms{'Id_Number'});
	my $user = $parms{'ac_user'};
	my $mode = $parms{'Mode'};
	my $ip = $parms{'ac_ipaddress'};
	$ip = '' unless defined($ip);

	if ($mode eq 'customer') {
		$ac_Col = 'ac_customer';
		$aff = $dbh->do("update customer set CO_Credit = CO_Credit + $amount 
						where CO_Number = $id");
	} else {
		$ac_Col = 'ac_ResNumber';
		$aff = $dbh->do("update reseller set RS_Credit = RS_Credit + $amount 
						where RS_Number = $id");
	}

	if ((! $aff) || ($aff == 0)) {
		return (undef, "Updating $mode balance failed. ($mode=$id, Amount=$amount): "
			. $dbh->errstr);
	}

	my $sth = $dbh->prepare("insert into addcredit set 
								$ac_Col = $id,
								ac_amount = $amount,
								ac_datetime = now(),
								ac_transaction = floor(rand() * 1000000000),
								ac_user = ?,
								ac_ipaddress = ?");
	$aff = $sth->execute($user, $ip);

	if ((! $aff) || ($aff == 0)) {
		return (undef, "Updating addcredit table failed. (user=$user, ip=$ip, $mode=$id): "
			. $dbh->errstr);
	}

	return (1, 'ok');
}

sub is_blank_str {
	my $v = shift;

	return 0 unless defined($v);

	$v =~ s/^\s*(.*)\s*$/$1/g;

	return ($v eq '');
}

sub make_a_float {
	my $n = shift;
	return 0 unless defined $n;
	eval {
		$n = sprintf('%f', $n);
	};
	$n = 0 if $@;
	return $n;
}

sub make_an_int {
	my $n = shift;
	return 0 unless defined $n;
	eval {
		$n = sprintf('%d', int($n));
	};
	$n = 0 if $@;
	return $n;
}

sub tellSecret {

	my $csock = IO::Socket::INET->new(
		PeerAddr => '127.0.0.1', PeerPort => 8230, Proto => 'tcp', Blocking => 1,
		ReuseAddr => 1) || return;

	my $secret;
	my $rv = recv($csock, $secret, 200, 0);

	if ((defined($rv)) && (defined($secret)) && (length($secret) > 20) &&
		($secret =~ /#>>(.{20,})<<#/)) {

		$secret = $1;
		return $secret;
	}
}

sub local_datetime {
	my $epoch = shift;
	$epoch = time() unless defined($epoch);

	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) =
                                                      localtime($epoch);

	$year += 1900; $mon++;

	return (sprintf("%d-%02d-%02d", $year, $mon, $mday),
		    sprintf("%02d:%02d:%02d", $hour, $min, $sec));
}

sub buildTime {
	my ($h, $m) = @_;

	$h = 0 if $h < 0;
	$m = 0 if $m < 0;

	my $ampm = 'AM';

	if ($h == 24) {
		return "11:59PM";
	} elsif ($h == 0) {
		$h = 12;
	} elsif ($h > 11) {
		$ampm = 'PM';
		if ($h > 12) {
			$h -= 12;
		}
	}

	return sprintf("%02d:%02d%2s",$h,$m,$ampm);
}

sub splitTime {
	my $whole = shift;

	# $whole has format HH:MMXM
	$whole =~ /\D*(\d*)\D*(\d*)(.*)/i;
	my $h = $1;
	$h = 12 if $h > 12;
	my $m = $2;
	$m = 59 if $m > 59;
	my $ampm = uc($3);
	if (($ampm ne 'AM') && ($ampm ne 'PM')) {
		$ampm = 'AM';
	}

	# hours need to be converted to 24H
	if ($h == 12) {
		# 12:00PM = noon
		if ($ampm eq 'AM') {
			$h = 0;
		}
	} else {
		if ($ampm eq 'PM') {
			$h += 12;
		}
	}

	return ($h, $m);
}

sub escapeJSON {
	my $jstr = shift;

	# double quotes "
	$jstr =~ s/"/\\"/g;

	# newlines
	$jstr =~ s/\n/\\n/g;

	# backslashes (except those of \n and \")
	$jstr =~ s/\\([^n"])/\\\\$1/g;

	# slashes
	$jstr =~ s/\//\\\//g;

	# other control chars are sanitized
	$jstr =~ s/[[:cntrl:]]/./g;

	return $jstr;
}

sub hhmmss {
	my $given = abs(shift); # seconds eg: 356.9863
	my $places = shift; # decimal places for secs

	my ($hr,$min,$sec) = (0,0,0.0);

	$hr = int($given/3600);
	my $rem = $given - ($hr * 3600);
	$min = int($rem/60);
	$rem -= $min * 60;
	$sec = $rem;

	if ((!defined($places)) || ($places == 0)) {
		return sprintf('%02d:%02d:%02d', $hr, $min, $sec);
	} else {
		my $fsz = $places + 3;
		return sprintf("%02d:%02d:%0${fsz}.${places}f", $hr, $min, $sec);
	}
}

sub sbncdr_parser {

	my $line = shift;
	my %cdr ;

	#2009-03-02,13:37:04,7709818787,4,MN,X007-robert-010f2808::1236018992.22714,HC16-OR4
	#2006-5-25,18:18:17,7022122009,8,AC,CP42-5-16-112,8-0*1280-528-?-?,17737721917
	#2009-01-02,19:08:31,7067378023,36,HU,D125-16-7-367,7-1*0-0-3-0.0,2

	if ($line !~ /([\d-]+),([\d\:]+),(\d{10}),(\d+),(\w{2,9}),([^,]+),([^,]+)(?:,(\d+))?/)	{
		return undef;
	}

	$cdr{'Date'} = $1;
	$cdr{'Time'} = $2;
	$cdr{'CalledNumber'} = $3;
	$cdr{'Duration'} = $4;
	$cdr{'Disposition'} = $5;
	$cdr{'LineId'} = $6;
	$cdr{'CallSetup'} = $7;
	$cdr{'ProspectNumber'} = $8;

	$cdr{'DoNotCall'} = 'N';
	$cdr{'Canada'} = 0;
	
	my $ac = substr($cdr{'CalledNumber'},0,3);
	if (($ac == 204) or ($ac == 289) or ($ac == 306) or ($ac == 403) or ($ac == 416) or 
	    ($ac == 418) or ($ac == 450) or ($ac == 506) or ($ac == 514) or ($ac == 519) or
		($ac == 604) or ($ac == 613) or ($ac == 647) or ($ac == 705) or ($ac == 709) or
		($ac == 778) or ($ac == 780) or ($ac == 807) or ($ac == 819) or ($ac == 867) or
		($ac == 902) or ($ac == 905)) {

		# canada
		$cdr{'Canada'} = 1;
	}


	if (!$cdr{'ProspectNumber'}) {
		$cdr{'ProspectNumber'} = 0;
	} elsif ($cdr{'ProspectNumber'} == 2) {
		$cdr{'DoNotCall'} = 'Y';
	}

	my ($dialer, $Tnum, $linenr) = ('UNKN', 1, 1);
	if ($cdr{'LineId'} =~ /([\w\d]+)-(\d+)-(\d+)-(\d+)/) {
		$dialer	= $1;
		$Tnum  	= $2;
		$linenr	= $3;
	}
	if ($cdr{'LineId'} =~ /([\w\d]+)-.*/) {
		$dialer	= $1;
	}
	$cdr{'Dialer'} = $dialer;
	$cdr{'Trunk'} = $Tnum;
	$cdr{'LineNumber'} = $linenr;
	
	$cdr{'Date'} =~ /(\d{4})-(\d\d)-(\d\d)/;
	$cdr{'Date-Year'} = $1;
	$cdr{'Date-Month'} = $2;
	$cdr{'Date-Day'} = $3;
	
	$cdr{'Time'} =~ /(\d\d):(\d\d):(\d\d)/;
	$cdr{'Time-Hour'} = $1;
	$cdr{'Time-Minute'} = $2;
	$cdr{'Time-Second'} = $3;
	
	$cdr{'CarrierBusy'} = 0;
	if ($cdr{'CallSetup'} =~ /-(546|556|554)-/) {
		$cdr{'CarrierBusy'} = 1;
	}

	$cdr{'LoopTime'} = 0.0;
	if ($cdr{'CallSetup'} =~ /.*LT-([.0-9]*).*/) {
		$cdr{'LoopTime'} = $1;
	}
	$cdr{'CarrierCode'} = 'X';
	
	# W011-W013 was Imran E (until 2009-11-02)

	# Z: Mikes VOIP @66.187.177.100
	# D: was BBCOM
	# B: is GCNS voip (from tested on 2009-10-29, then in prod from 2009-11-10)
	
	my %CARRIERS = (
		'A' => [ # qwest
			'D201',  # null dialers
			'D105', 'D106', 'D107', 'D108', 'D119', 'D120', 'D157', # connected to nvr-6
			'D103', 'D104', 'D145', # connected to nvr-10
			'D117', 'D118', 'D146', 'D158', # connected to nvr-11

			],
		'F' => [ # global crossing
			'D202',	 # null dialers
			'D114', 'D115', 'D116', 'D125', 'D143', # connected to nvr-1
			'D101', 'D102', 'D111', 'D112', 'D113', 'D123', 'D124', 'D144',  # connected to nvr-2 [D112 crashed hard-drive Nov09]
			'D110', 'D121', 'D122', 'D141', 'D142', 'D159', # connected to nvr-4
			'D109', 'D147', 'D148', 'D155', 'D156', 'D160', # connected to nvr-8
			],
		'G' => [ 'W005', 'W010' ], # monkey biz
		'H' => [ 'W008', 'W009' ], # massive
		'T' => [ # test
			'D127', 'D128', 'D130', 'D132', 'D133', 'D134', # connected to nvr-9
			'WTST', # when run on swift
			],
		'U' => [ 
			'D126', 'D129', 'D131', 'D154', 
			'W003', 'W004', 'W006', 'W007', 'W011', 'W012', 'W013', 'W014',
			'X001', 'X002', 'X003', 'X007', 'X012',
			'W05A', 'W05B'], # unknown
	);

	if ($cdr{'LineId'} =~ /[\w\d]+-C-([A-Z])/) {
		$cdr{'CarrierCode'} = $1;
	} else {
		# search based on dialer in %CARRIERS
		for my $carr (keys %CARRIERS) {
			if (grep($_ eq $dialer, @{$CARRIERS{$carr}})) {
				$cdr{'CarrierCode'} = $carr;
				last;
			}
		}
	}

	if ($cdr{'CarrierCode'} eq 'X') {
		die "failed to determine carrier for dialer $dialer";
	}

	return \%cdr;
}

sub determine_CID_for_project {

	my ($dbh, $PJ_OrigPhoneNr, $PJ_CustNumber) = @_;

	my $CID = $PJ_OrigPhoneNr;
	if ((! defined($CID)) || ($CID eq '')) {
		# fetch a reseller default CID
		my $rcid = $dbh->selectrow_hashref("select RC_CallerId, RC_Reseller from
			rescallerid, customer where CO_Number =  $PJ_CustNumber
			and RC_Reseller = CO_ResNumber and RC_DefaultFlag = 'Y' 
			order by rand() limit 1");

		if (defined($rcid->{'RC_CallerId'})) {
			$CID = $rcid->{'RC_CallerId'};
		}
	}

	return $CID;
}

sub pjnumbers_get {
	# not carrier specific

	my ($dbh, $pjnum, $count, $nref) = @_;

	my $pnTableName = "projectnumbers_$pjnum";
	my $t0 = [gettimeofday()]; # benchmark timer starts

	my $res = $dbh->selectrow_hashref("select * from project where PJ_Number = $pjnum");
	if (! defined($res)) {
		return (0,0);
	}

	my $tzones = timezones_allowed(
		$res->{'PJ_Local_Time_Start'},
		$res->{'PJ_Local_Start_Min'},
		$res->{'PJ_Local_Time_Stop'},
		$res->{'PJ_Local_Stop_Min'});


	my $zone_predicate = '(';
	my $sep = '';
	for my $tz (@$tzones) {
		$zone_predicate .= "$sep PN_TimeZone = $tz";
		$sep = " or";
	}
	$zone_predicate .= ')';
	if ($zone_predicate eq '()') {
		return (0,0);
	}

	$dbh->do("create temporary table tempcache (
		Num char(10), 
		BestCarriers char(9),
		AltCarriers char(9) ) Engine = MEMORY");

	$dbh->do(
		"insert into tempcache select 
		PN_PhoneNumber, PN_BestCarriers, PN_AltCarriers
		from $pnTableName
		where PN_Status = 'R' and
		$zone_predicate
		order by PN_Seq limit $count");

	my $nres = $dbh->selectrow_hashref(
		"select count(*) as RowsCount from tempcache");

	my $actual = 0;
	if ($nres->{'RowsCount'} > 0) {
		# tempcache has something
		$dbh->do("update $pnTableName, tempcache
			set PN_Sent_Time = now(), PN_Status = 'S'
			where PN_PhoneNumber = Num");

		$nres = $dbh->selectall_arrayref(
			"select Num, BestCarriers, AltCarriers from tempcache");
		$actual = scalar(@$nres);
		push @$nref, @$nres;
	}

	$dbh->do("drop table tempcache");
	my $elapsed = tv_interval($t0, [gettimeofday()]);
	return ($actual, $elapsed);
}

sub dialnumbers_get {
	my ($dbh, $pjnum, $carrier, $count, $nref) = @_;
	my $cachetbl = "numberscache_$carrier";
	my $t0 = [gettimeofday()]; # benchmark timer starts
	
	my $actual = 0;

	# we 'order by NC_Id' so that numbers cannot sit
	# in the cache for a long time (running over tz etc)
	my $limit = $count;
	if ($count < 10) {
		$limit = $count * 5;
	}
	my $nres = $dbh->selectall_arrayref(
		"select NC_Id, NC_PhoneNumber from $cachetbl
		where NC_Project = $pjnum order by NC_Id
		limit $limit", { Slice => {}});

	for my $nrow (@$nres) {
		my $del = $dbh->do("delete from $cachetbl 
			where NC_Id = " . $nrow->{'NC_Id'});

		if ($del > 0) {
			$actual++;
			push @$nref, $nrow->{'NC_PhoneNumber'};
		}
	}
	my $elapsed = tv_interval($t0, [gettimeofday()]);
	return ($actual, $elapsed);
}

sub dialnumbers_put {
	# numbers are returned unused
	my ($dbh, $pjnum, $nref) = @_;
	my $pnTableName = "projectnumbers_$pjnum";
	my $t0 = [gettimeofday()]; # benchmark timer starts
	
   # Note: when a number is returned, it may not exist on the
   # projectnumbers table anymore since the file may have been deleted,
   # in these cases, we don't care about the number.

	my $rcount = 0;
	my $rmiss  = 0;
	for my $num (@$nref) {
		my $updated = $dbh->do("update $pnTableName
				set PN_Status = 'R', PN_Sent_Time = null
				where PN_PhoneNumber = '$num' and PN_Status = 'S'");
		if ($updated == 1) {
			$rcount++;
		} else {
			$rmiss++;
		}
	}

	my $elapsed = tv_interval($t0, [gettimeofday()]);
	return ($rcount, $rmiss, $elapsed);
}

sub timezones_allowed {

	my $start_hour = shift;
	my $start_min = shift;
	my $stop_hour = shift;
	my $stop_min = shift;
	my $now_hour = shift;
	my $now_min = shift;

	if (! defined($now_hour)) {
		# set current system time
		my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) =
                                                localtime(time);
		$now_hour = $hour;
		$now_min = $min;
	}


	# convert to "decimal" time
	my $lstart = $start_hour + ($start_min / 60);
	my $lstop = $stop_hour + ($stop_min / 60);

	my @ret;
	for (my $tznum = 0; $tznum <= 23; $tznum++) {

		# localize the current time to $tznum
		my $nowLocal_hour = $now_hour - $tznum;
		if ($nowLocal_hour < 0) {
			$nowLocal_hour += 24;
		}

		# convert to "decimal" time
		my $lnow = $nowLocal_hour + ($now_min / 60);

		if (($lnow >= $lstart) && ($lnow < $lstop)) {
			push @ret, $tznum;
		}
	}

	return \@ret;
}

sub who_am_I {

	my $me = `hostname`;
	$me =~ tr/0-9a-z//cd;
	return $me;

}
	
sub move_leads {

	my ($source, $target) = @_;

	my $me = `hostname`;
	$me =~ tr/0-9a-z//cd;

	if ($me eq 'swift') {
		system("mv '$source' '$target'");
	} else {
		system("scp -q -P 8946 '$source' root\@10.80.2.32:$target");
		unlink($source);
	}
}

sub move_from_db0 {

	my ($source, $target) = @_;

	my $me = who_am_I();

	if (($me eq 'swift') || ($me eq 'b1-db')) {
		system("mv '$source' '$target'");
	} else {
		system("scp -q -P 8946 root\@10.80.2.32:$source '$target'");
		# the in-out dir is purged in the nightly script
	}
}

sub cc_host {

	# cold calling host

	my $me = who_am_I();

	return 'localhost' if $me eq 'swift'; 
	return 'localhost' if $me eq 'vaio'; 
	return '10.80.2.29'; # default to w129
}
	
sub db_host {

	my $me = who_am_I();

	return 'localhost' if $me eq 'swift'; 
	return '10.80.2.32'; # default to prod
}
	
sub db2file {
	my $dname = shift;
	my $target = shift;

	my $host = db_host();
	my $me = who_am_I();
	system("scp -q -P 8946 'mysql\@$host:in-out/$dname' '$target'");
}

sub db_rmfile {
	my $dname = shift;

	my $host = db_host();
	my $me = who_am_I();
	system("echo 'rm /var/lib/mysql/in-out/$dname' | sftp -oPort=8946 'mysql\@$host' > /dev/null 2> /dev/null");
}

sub db_connect {
	my $host = shift;

	$host = db_host() unless defined $host;

	my $dbh = DBI->connect("DBI:mysql:dialer;host=$host", 'root', 'sbntele')
	 || croak("Cannot Connect to database: $!");

	return $dbh;
}

sub sbn2_connect {
	my $me = who_am_I();

	my $host;
	$host = 'localhost'  if $me eq 'swift'; 
	$host = 'localhost'  if $me eq 'b1-db'; 
	$host = '10.80.2.32' if $me eq 'b1-ap';

	my $sbn2 = DBI->connect("DBI:mysql:sbn2;host=$host", 'root', 'sbntele')
	 || croak("Cannot Connect to database: $!");

	return $sbn2;
}

sub daemonize {
	my $logdir = shift;
	my $prog = $0;
	$prog =~ s/.*\/(.*)$/$1/; # strip off the path

	# first check if we are already running
	for my $ps (`ps -o pid= -C $prog`) {
		if ($ps != $$) {
			die "Not continuing, $prog already running with pid=$ps";
		}
	}

	$logdir = '/var/log' unless defined($logdir);

	use POSIX qw(setsid);
	chdir '/' or die "Can't chdir to /: $!";
	umask 0;
	open STDIN, '/dev/null' or die "Can't read /dev/null: $!";
	open STDOUT, '>>', "$logdir/$prog.out" or die "Failed to redirect stdout to $logdir/$prog.out: $!";
	open STDERR, '>>', "$logdir/$prog.err" or die $!;
	defined(my $pid = fork) or die "Can't fork: $!";
	exit if $pid;
	setsid() or die "Can't start a new session: $!";

}

sub read_PHP_session {
	my $sessid = shift;
	
	my $sessfile = "/var/lib/php5/sess_$sessid";

	open(SESS, "<", $sessfile) or return undef;

	my %session;
	while (<SESS>) {
		for my $sv (split /;/) {
			if ($sv =~ /(.*)\|.*:(.*)/) {
				my ($name, $val) = ($1, $2);
				$val =~ s/"([^"]*)"/$1/;
				$session{$name} = $val;
			}
		}
	}

	return \%session;
}

sub north_american_phnumber {
	my $instr = shift;
	$instr =~ tr/0-9//cd; # remove everything thats not a digit
	$instr =~ s/^1(\d{10})/$1/; # remove leading 1's on 11 digit numbers
	return $instr;
}

sub custdnc_add {
	my $custid = shift;
	my $numlist = shift; # array ref of numbers

	my $sbn2 = DialerUtils::sbn2_connect();
	my $count = 0;
	$custid = 0 unless (defined($custid)) && ($custid > 0);

	for my $ph (@$numlist) {
		my $n = north_american_phnumber($ph);
		if ($n =~ /^\d{10}$/) {

			my $aff = $sbn2->do("insert into custdnc 
				(CD_PhoneNumber, CD_LastContactDT, CD_LastContactCust, CD_AddedDT, CD_AddedCust)
				values ($n, now(), $custid, now(), $custid) 
				on duplicate key update
				CD_LastContactDT = now(), CD_LastContactCust = $custid");			
			$count++ if $aff > 0;
		}
	}

	$sbn2->disconnect;
	return $count;
}

sub clean_file {

	# cleans text files to numbers per line
	my $infile = shift;
	my $outfile = shift; # can be the same as infile

	my $cleanf = "$infile-wrktmp-" . rand();
	my $numcount = 0;

	open(CLEAN, ">", $cleanf);
	open(RAW, "<", $infile);
	while (<RAW>) {
		my $n = north_american_phnumber($_);
		if ($n =~ /^\d{10}$/) {
			print CLEAN "$n\n";
			$numcount++;
		}
	}
	close(CLEAN);
	close(RAW);	
	system("mv '$cleanf' '$outfile'");
	warn "$numcount clean numbers in '$outfile'";
	return $numcount;
}

sub valid_values_str {
	my $v = shift;

	return 0 unless defined $v;

	for my $vv (@_) {
		if ($v eq $vv) {
			return 1;
		}
	}
	return 0;
}

sub step_one {
	my $req = shift;
	my $dbh = shift;
	my $Z_CO_Number = shift; # customer that the request is dealing with
	my $Z_PJ_Number = shift; # project (optional) that the request is dealing with

	$Z_CO_Number = 0 if (!defined($Z_CO_Number));
	$Z_PJ_Number = 0 if (!defined($Z_PJ_Number));
	
	my $data = {'ErrStr' => '', 'Z_CO_Permitted' => 'No', 'Z_PJ_Permitted' => 'No' };

	formdata($req, $data);

	my $sessid;
	if (defined($data->{'SessionId'})) {
		$sessid = $data->{'SessionId'};
	} else {
		if (defined($req->jar)) {
			$sessid = $req->jar->get('PHPSESSID');
		} else {
			$data->{'ErrStr'} = 'Not logged in';
			return $data;
		}
	}

	$data->{'Session'} = read_PHP_session($sessid);

	my $cust;
	if ($Z_CO_Number > 0) {
		$cust = $dbh->selectrow_hashref("select * from customer
			where CO_Number = $Z_CO_Number limit 1");
		if (! defined($cust->{'CO_ResNumber'})) {
			$data->{'ErrStr'} = 'Invalid customer context';
			return $data;
		} else {
			$data->{'ContextCustomer'} = $cust;
		}
	}

	my $proj;
	if ($Z_PJ_Number > 0) {
		$proj = $dbh->selectrow_hashref("select * from project
			where PJ_Number = $Z_PJ_Number and PJ_Visible = 1 limit 1");
		if (! defined($proj->{'PJ_CustNumber'})) {
			$data->{'ErrStr'} = 'Invalid project context';
			return $data;
		} elsif (($Z_CO_Number > 0) && ($Z_CO_Number != $proj->{'PJ_CustNumber'})) {
			$data->{'ErrStr'} = 'Mismatched project context';
			return $data;
		} else {
			$data->{'ContextProject'} = $proj;
		}
	}

	if ((! defined($data->{'Session'}{'L_Level'})) ||
		($data->{'Session'}{'L_Level'} == 0)) {
		$data->{'ErrStr'} = 'Not permitted. Login first.';
		return $data;
	}

	my $level = $data->{'Session'}{'L_Level'};

	if ($level == 6) { 
		# finan/tech
		$data->{'Z_CO_Permitted'} = 'Yes' if ($Z_CO_Number > 0);
		$data->{'Z_PJ_Permitted'} = 'Yes' if ($Z_PJ_Number > 0);

		$data->{'ContextReseller'} = $dbh->selectrow_hashref("select * from reseller
			where RS_Number = 1");
		return $data;
	}

	if ($level == 5) {
		# reseller
		if ((! defined($data->{'Session'}{'L_OnlyReseller'})) ||
			($data->{'Session'}{'L_OnlyReseller'} == 0)) {
			$data->{'ErrStr'} = 'Reseller permission restriction. Login again.';
			return $data;
		}

		if (($Z_CO_Number > 0) && ($cust->{'CO_ResNumber'} == $data->{'Session'}{'L_OnlyReseller'})) {
			$data->{'Z_CO_Permitted'} = 'Yes';
		}

		$data->{'Z_PJ_Permitted'} = 'Yes' if ($Z_PJ_Number > 0);
		$data->{'ContextReseller'} = $dbh->selectrow_hashref("select * from reseller
			where RS_Number = " . $data->{'Session'}{'L_OnlyReseller'});
		return $data;
	}

	if (($level > 0) && ($level <= 4)) {
		if ((! defined($data->{'Session'}{'L_OnlyCustomer'})) ||
			($data->{'Session'}{'L_OnlyCustomer'} == 0)) {
			$data->{'ErrStr'} = 'Customer permission restriction. Login again.';
			return $data;
		}

		if ($Z_CO_Number != $data->{'Session'}{'L_OnlyCustomer'}) {
			$data->{'ErrStr'} = 'Insufficient customer priveledge';
			return $data;
		} else {
			$data->{'Z_CO_Permitted'} = 'Yes';

			if ($Z_PJ_Number > 0) {
				my $user = $data->{'Session'}{'L_Number'};

				if ((defined($user)) && ($user > 0) 
					&& ($level == 1) &&	($user != $proj->{'PJ_User'})) {

					$data->{'ErrStr'} = 'Insufficient project priveledge';
					return $data;
				} else {
					$data->{'Z_PJ_Permitted'} = 'Yes';
				}
			}
			return $data;
		}
	}
		
	return $data;
}

sub formdata {
	my $req = shift;
	my $data = shift;

	$data->{'ErrStr'} = '';

	if (defined($req->param)) {
		for my $k (keys %{$req->param}) {
			$data->{$k} = $req->param->{$k};
		}
	}
}

sub disconnect_agent {
	my $dbhandle = shift;
	my $Proj = shift;
	my $AgentId = shift;

	if ($AgentId != 1111) {
		$dbhandle->do("update agent set 
			AG_Lst_change = now(), AG_BridgedTo = null 
			where AG_Number = $AgentId");
	}
}

sub bridge_agent {
	my $dbhandle = shift;
	my $AgentId = shift;
	my $PhProspect = shift;

	return unless defined($AgentId);
	return unless ($AgentId > 0);
	return unless defined($PhProspect);
	return unless defined($dbhandle);

	$dbhandle->do("update agent set 
		AG_Lst_change = current_timestamp(), 
		AG_BridgedTo = '$PhProspect', AG_Paused = 'Y'
		where AG_Number = $AgentId");
}

sub connect_agent {
	my $dbhandle = shift;
	my $Proj = shift;
	my $PhProspect = shift;

	# returns reference to %ag
	my %ag = ( AgentPhoneNumber => undef, AgentId => undef );

	# check if we have a call center
	my $row = $dbhandle->selectrow_hashref("select PJ_PhoneCallC 
		from project where PJ_Number=$Proj"); 			
	if (length($row->{'PJ_PhoneCallC'}) == 10) {
		# use the call center number
		%ag = (	AgentPhoneNumber	=> $row->{'PJ_PhoneCallC'},
				AgentId		=> '1111');
	} else {
		# look for an agent (first available ones then as a last resort a connected one)
		$row = $dbhandle->selectrow_hashref(
			"select AG_Number,AG_CallBack,AG_SessionId,AG_Status from agent 
			where AG_Status = 'A' and AG_Project=$Proj 
			order by AG_BridgedTo, AG_Lst_change limit 1");

		if (defined($row->{'AG_Number'})) {
			# make the agent connected

			bridge_agent($dbhandle, $row->{'AG_Number'}, $PhProspect);

			%ag = (	AgentPhoneNumber	=> $row->{'AG_CallBack'},
					AgentId		=> $row->{'AG_Number'} );
		}
	}

	return \%ag;
}

sub send_email {
	my $to = shift;
	my $from = shift;
	my $subject = shift;
	my $body = shift;

	use Net::SMTP;

	my $em =<<EOM
To: $to
From: $from
Subject: $subject

$body
EOM
;

	my $smtp = Net::SMTP->new("10.80.2.1", Timeout => 60, Debug => 0) or die "failed to smtp: $!";
	$smtp->mail($from);
	$smtp->to($to);
	$smtp->data();
	$smtp->datasend($em);
	$smtp->dataend();
	$smtp->quit;

}

sub email_to_support {
	my $subject = shift;
	my $body = shift;

	use Net::SMTP;

	my $em =<<EOM
To: support\@quickdials.com
From: root\@quickdials.com
Subject: $subject

$body
EOM
;

	my $smtp = Net::SMTP->new("10.9.2.1", Timeout => 60, Debug => 0) or die "failed to smtp: $!";
	$smtp->mail('root@quickdials.com');
	$smtp->to('support@quickdials.com');
	$smtp->to('sbntech@yahoo.com');
	$smtp->data();
	$smtp->datasend($em);
	$smtp->dataend();
	$smtp->quit;

}

1;
