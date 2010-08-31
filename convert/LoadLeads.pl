#!/usr/bin/perl

use strict;
use warnings;

use lib '/home/grant/H3/www/perl/';
use DialerUtils;
use lib '/home/grant/H3/convert/npanxx-data';
use Rates;
use Time::HiRes qw( gettimeofday tv_interval );
use CDB_File;
use JSON;
use Text::CSV_XS;

my $dbh;
my $r;
my $sbn2;
my $t0 = [gettimeofday()];
my $sleep = $ARGV[0];
$sleep = 60 unless defined $sleep;

for my $prog (`ps -o pid= -C LoadLeads.pl`) {
	if ($prog != $$) {
		die "Not continuing, already running with pid=$prog";
	}
}

DialerUtils::daemonize();
open(PID, ">", "/var/run/LoadLeads.pid");
print PID $$;
close(PID);

my $running = 1;

sub flog {
	my $lvl = shift;
	my $msg = shift;

	my ($dt, $tm) = DialerUtils::local_datetime();

	my $t1 = [gettimeofday()];
	my $elapsed = tv_interval($t0, $t1);
	my $m = sprintf('%0.3f', $elapsed);
	$t0  = $t1;

	print LOG "$dt $tm ($m) $lvl: $msg\n";
}

sub exit_handler {
	my $sig = shift;
	flog('TERMINATING', "SIG$sig caught");
	$running = 0;
}

$SIG{'INT'} = \&exit_handler;
$SIG{'QUIT'} = \&exit_handler;
$SIG{'TERM'} = \&exit_handler;

sub prep_number {
	my $number = shift;
	my $NFrow = shift;
	my $data = shift;
	my $OUTF = shift;
	my $scrubCode = shift;
	# XC=Cust DNC; XM=Main Dnc; XR=No Route; XP=Mobile; XN=Non-connect; XX=Militant; XF=Footprint; XD=Duplicate; XE=Expensive

	my $nn = $r->lookup_number($number, $data->{'ContextProject'}->{'PJ_CustNumber'}, $data->{'ContextCustomer'}->{'CO_ResNumber'});
	my $statecode = $nn->{'StateCode'};
	my $timezone = $nn->{'TimeZone'};

	my $res;
	
	if ((!defined($nn)) || ($nn->{'Routable'} == 0)) {
		# No Routes
		$scrubCode = 'XR';
	} 
	
	if ((!defined($scrubCode)) && ($NFrow->{'NF_CustScrub'} ne "'N'")) {
		# customer DNC 
		# Jul 13, 2009: changed to the one big list
		$res = $sbn2->selectrow_hashref("select CD_PhoneNumber from custdnc 
			where CD_PhoneNumber = '$number' and
			CD_LastContactDT > date_sub(now(), interval 3 month)");
		if (defined($res->{'CD_PhoneNumber'})) {
			$scrubCode = 'XC';
		}
	}

	if ((!defined($scrubCode)) && ($NFrow->{'NF_MobileScrub'} ne "'N'") && ($nn->{'Type'} eq 'MOBILE')) {
		# mobile scrubbing
		$scrubCode = 'XP';
	}

	# non-connect scrubbing
	if ((!defined($scrubCode)) && ($NFrow->{'NF_MainScrub'} ne "'N'") && ($data->{'ContextCustomer'}->{'CO_ResNumber'} != 77)) {
		$res = $sbn2->selectrow_hashref("select DN_PhoneNumber from dncnonconn where DN_PhoneNumber = '$number'");
		if (defined($res->{'DN_PhoneNumber'})) {
			$scrubCode = 'XN';
		}
	}

	# militant scrubbing
	$res = $sbn2->selectrow_hashref("select PhNumber from dncmilitant where PhNumber = '$number'");
	if (defined($res->{'PhNumber'})) {
		$scrubCode = 'XX';
	}

	if (defined($nn->{'ScrubType'})) {
		$scrubCode = $nn->{'ScrubType'};
	}

	my $BestCarriers = $nn->{'BestCarriers'};
	my $AltCarriers = $nn->{'AltCarriers'};
	$AltCarriers = '\N' unless length($AltCarriers) > 0;
	$scrubCode = '\N' unless defined($scrubCode) and length($scrubCode) == 2;
	print $OUTF "$number\t$timezone\t$BestCarriers\t$AltCarriers\t$scrubCode\n";
}

sub prep_file {
	my $fname = shift;
	my $NFrow = shift;
	my $data = shift;

	my $cdbdir = '/dialer/maindnc';
	if (! -d $cdbdir) {
		die "ERROR: missing maindnc dir $cdbdir containing cdb data";
	}

	# read and clean the input file into memory - sorted into prefix buckets
	open INF, '<', $fname || die "failed opening $fname: $!";
	my %numbers;
	my $eof = 0;
	my $buf;

	# fancy reading where lines can end in any kind control chars
	while (! $eof) {

		my $rbuf;
		my $rc = read INF, $rbuf, 10;
		if (defined($rc)) {
			if ($rc == 0) {
				$eof = 1;
			} else {
				$buf .= $rbuf;
			}
		} else {
			warn "read error";
			$eof = 1;
		}

		while (length($buf) > 0) {

			if ($buf =~ s/^[[:cntrl:]]*([^[:cntrl:]]*)([[:cntrl:]]+)(.*)/$3/s) {
				my $ln = $1;
				if (length($ln) > 0) {
					my $n = DialerUtils::north_american_phnumber($ln);
					if ($n =~ /^[2-9]\d{2}[2-9]\d{6}$/) {
						my $prefix = substr($n,0,2);
						my $suffix = substr($n,2);
						push @{$numbers{$prefix}}, $suffix;
						$NFrow->{'NF_StartTotal'}++;
					}
				}
			} else {
				last;
			}
		}

		if ($eof) {
			my $ln = $buf;
			if (length($ln) > 0) {
				my $n = DialerUtils::north_american_phnumber($ln);
				if ($n =~ /^[2-9]\d{2}[2-9]\d{6}$/) {
					my $prefix = substr($n,0,2);
					my $suffix = substr($n,2);
					push @{$numbers{$prefix}}, $suffix;
					$NFrow->{'NF_StartTotal'}++;
				}
			}
		}
	}
	
	close INF;

	# scrub
	my $OUTF;
	open $OUTF, '>', "$fname.clean" || die "failed opening $fname.clean: $!";

	for my $prefix (keys %numbers) {
		if ($NFrow->{'NF_MainScrub'} ne "'N'") {
			my %DNC;
			if (-f "$cdbdir/$prefix.cdb") {
				tie (%DNC, 'CDB_File', "$cdbdir/$prefix.cdb") or die "tie failed for $cdbdir/$prefix.cdb: $!";
			}

			for my $suffix (@{$numbers{$prefix}}) {
				if (defined($DNC{$suffix})) {
					prep_number("$prefix$suffix", $NFrow, $data, $OUTF, 'XM');
				} else {
					prep_number("$prefix$suffix", $NFrow, $data, $OUTF);
				}
			}

			if (-f "$cdbdir/$prefix.cdb") {
				untie %DNC;
			}
		} else {
			for my $suffix (@{$numbers{$prefix}}) {
				prep_number("$prefix$suffix", $NFrow, $data, $OUTF);
			}
		}
		delete $numbers{$prefix};
	}
	close $OUTF;
}

sub convert {
	my $FullPath = shift;
	my $FileName = shift;
	my $mainscrub = shift;
	my $custscrub = shift;
	my $mobilescrub = shift;
	my $data = shift; # PJ_Number, ContextProject->PJ_CustNumber
	my $headers = shift;

	flog("INFO", "Converting " . $data->{'NF_FileName'} . ' for project '
		. $data->{'PJ_Number'} . ' {' . $data->{'ContextProject'}->{'PJ_Description'} . 
		'} with JobId=' . $data->{'JobId'});

	my $dfile = "/dialer/projects/workqueue/LoadLeads-DATA-" . $data->{'JobId'};

	if (! -e $FullPath) {
		warn "ERROR: FullPath=$FullPath does not exist " .
		' for project ' . $data->{'PJ_Number'} . 
		' (Customer=' . $data->{'ContextProject'}->{'PJ_CustNumber'} . ')';
		return;
	}

	my $rcount = 0;
	my %NFrow;

	$NFrow{'NF_MainScrub'} = "'$mainscrub'";
	$NFrow{'NF_CustScrub'} = "'$custscrub'";
	$NFrow{'NF_MobileScrub'} = "'$mobilescrub'";
	if ((defined($headers)) && (length($headers) > 1)) {
		$NFrow{'NF_ColumnHeadings'} = "'$headers'";
	} else {
		$NFrow{'NF_ColumnHeadings'} = "null";
	}

	# clean the data and off-line scrubbing
	prep_file($FullPath, \%NFrow, $data);
	unlink($FullPath);
	my $cleanf = "$FullPath.clean";
	flog('INFO', "prep_file completed. NF_StartTotal = " . $NFrow{'NF_StartTotal'});

	# how many chunks of 50k do we have
	my $spmax = int($NFrow{'NF_StartTotal'} / 50000) + 1;

	# load the file into the database
	$dbh->do("create table numload_temp (
			PhNumber char(10) not null, 
			SplitPoint integer default 0,
			Timezone INTEGER unsigned NOT NULL DEFAULT 0,
			BestCarriers char(9) NOT NULL,
			AltCarriers char(9),
			ScrubCode char(2),
			PRIMARY KEY(PhNumber))");
	my $tname = DialerUtils::file2db($cleanf);
	unlink($cleanf);
	$dbh->do("load data infile 'in-out/$tname' ignore into table 
				numload_temp (PhNumber,Timezone,BestCarriers,AltCarriers, ScrubCode) 
				set SplitPoint = floor(rand() * $spmax)");
	DialerUtils::db_rmfile($tname);

	# in-file dupes
	$NFrow{'NF_ScrubDuplicate'} = 0;
	my $res = $dbh->selectrow_arrayref("select count(*)
		from numload_temp");
	my $tcount = $res->[0];
	$NFrow{'NF_ScrubDuplicate'} = $NFrow{'NF_StartTotal'} - $tcount;
	
	flog('INFO', "loaded $tcount rows into temporary table. In-file dupes=" 
		. $NFrow{'NF_ScrubDuplicate'});

	# prep 
	my $pnTableName = "projectnumbers_" . $data->{'PJ_Number'};
	$dbh->do("create table if not exists $pnTableName like projectnumbers");

	# Crossfile De-duping
	$rcount = $dbh->do("delete from numload_temp where
		exists (select 'x' from $pnTableName where PN_PhoneNumber = PhNumber)");

	if ((defined($rcount)) && ($rcount > 0)) {
		$NFrow{'NF_ScrubDuplicate'} += $rcount;
		flog('INFO', "universal duplicates numbers scrubbed: $rcount");
	}

	# store a numberfiles row
	$NFrow{'NF_FileName'} = "'$FileName'";
	my $NFcols = "";
	my $NFvals = "";
	for my $NFk (keys %NFrow) {
		if (defined($NFrow{$NFk})) {
			$NFcols .= "$NFk, ";
			$NFvals .= $NFrow{$NFk} . ",";
		}
	}
	$dbh->do("insert into numberfiles ($NFcols NF_Uploaded_Time, NF_Project) values
		($NFvals now(), " . $data->{'PJ_Number'} . ")");

	my $lid = $dbh->last_insert_id(undef,undef,'numberfiles','NF_FileNumber');
	my $lidpre = substr($lid,0,3) * 100000;
	flog('INFO', "stored a numberfiles row NF_FileNumber=$lid");

	# load numbers into projectnumbers_99999 table
	my $merged = 0;
	for (my $splitpoint = 0; $splitpoint < $spmax; $splitpoint++) {
		if ($splitpoint > 0) {
			sleep 2; # releasing the table lock for number-helper
			flog('DEBUG', "was sleeping");
		}

		my $aff = $dbh->do("insert ignore into $pnTableName 
			(PN_PhoneNumber, PN_FileNumber, PN_Sent_Time, PN_Status, PN_Seq, 
				PN_BestCarriers, PN_AltCarriers, PN_Timezone, PN_CallResult, PN_DoNotCall)
			select PhNumber, $lid, null, 
			IF(ScrubCode is null,'R','X'), 
			($lidpre + floor(rand()*100000)),
			BestCarriers, AltCarriers, Timezone, ScrubCode,
			IF(ScrubCode is null,'N','Y') from numload_temp 
			where SplitPoint = $splitpoint");
		$merged += $aff;
		flog('DEBUG', "merged a $aff row chunk, of temporary numload_temp into $pnTableName, $merged so far, (" .
			sprintf('%d', $splitpoint + 1) . " of $spmax chunks)");
	}
	flog('INFO', "merged the temporary numload_temp into $pnTableName ($spmax chunks)");

	# cleanup
	$dbh->do("drop table numload_temp");
	flog('INFO', "Finished, dropped numload_temp");

	flog('INFO', "converted $FileName ($merged rows) mainscrub=$mainscrub custscrub=$custscrub mobilescrub=$mobilescrub " .
		' for project ' . $data->{'PJ_Number'} .  ' (Customer=' . $data->{'ContextProject'}->{'PJ_CustNumber'} . ")");
}

sub do_numfile {
	my ($data) = @_;

	my $projid = $data->{'PJ_Number'};
	my $dnc = $data->{'ScrubMainDncInd'};
	my $custdnc = $data->{'ScrubCustDncInd'};
	my $mobilescrub = $data->{'ScrubMobilesInd'};
	my $base = $data->{'NF_FileName'};
	my $fullname = "/dialer/projects/workqueue/LoadLeads-DATA-" . $data->{'JobId'};

	if ($base =~ /\.txt$/i) {
		convert($fullname, $base, $dnc, $custdnc, $mobilescrub, $data);
	} elsif ($base =~ /\.csv$/i) {
		my $leadsfile = "$fullname.txt";
		my $good = 0;
		my $skip = 0;
		my $csv = Text::CSV_XS->new({ binary => 1 });
		open my $PUfile, '<', $fullname || warn "Failed to open $fullname: $!";
		open(PUTXT, '>', $leadsfile) || warn "Failed to open $leadsfile: $!";

		my $tempTbl = "pop$projid";
		$dbh->do("create temporary table $tempTbl (
					popPhone char(10) not null,
					popData text,
					PRIMARY KEY(popPhone)
				  ) ENGINE=MyISAM");
			# note: MEMORY engine does not support text columns

		my $sth = $dbh->prepare("insert ignore into $tempTbl (popPhone, popData)" .
			 " values (?, ?)");

		my $headers;
		my $hsep = '';
		my $phcol; # column index of the phone number

		while (my $row = $csv->getline($PUfile)) {

			if (! defined($headers)) {
				$headers = '';

				# determine which column is the phone number
				for (my $p = 0; $p < scalar(@$row); $p++) {
				    my $c0 = $row->[$p];
					$c0 =~ s/[[:cntrl:]]//g; # remove newlines etc.
					my $c = DialerUtils::escapeJSON($c0);
					$hsep = ',' if (length($headers) > 1);

					if (length($c) == 0) {
						$headers .= "$hsep\"Blank_$p\"";
					} else {
						if ((!defined($phcol)) && (uc($c) =~ /PHONE/)) {
							$phcol = $p;
						} else {
							$headers .= "$hsep\"$c\"";
						}
					}
				}
				if (defined($phcol)) {
					next;
				} else {
					# could not determine the column containg phone numbers
					last;
				}
			}

			my $json;
			my $phone;
			for (my $p = 0; $p < scalar(@$row); $p++) {
				my $value = DialerUtils::escapeJSON($row->[$p]);

				if ($p == $phcol) {
					$phone = $value;
					$phone =~ tr/0-9//cd;
				} else {
					$json .= "," if defined $json;
					$json .= "\"$value\"";
				}
			}
			if ((defined($phone)) && ($phone =~ /1?(\d{10})/)) {
				$phone = $1;
				print PUTXT "$phone\n";
				$sth->execute($phone,$json);
				$good++;
			} else {
				$skip++;
			}
		}

		close($PUfile);
		close(PUTXT);

		flog('INFO',"$base for project $projid had $good popup rows and $skip were skipped\nHeaders:$headers");
		convert($leadsfile, $base, $dnc, $custdnc, $mobilescrub, $data, $headers);

		my $prows = $dbh->do("update projectnumbers_$projid, $tempTbl 
					set PN_Popdata = popData where popPhone = PN_PhoneNumber");
		flog('INFO',"$base for project $projid had $prows rows of data merged");
		$dbh->do("drop temporary table $tempTbl");

	} elsif ($base =~ /\.xls$/i) {
		use Spreadsheet::ParseExcel;
		my $oExcel = new Spreadsheet::ParseExcel;
		my $oBook = $oExcel->Parse($fullname);

		open(XDAT, ">", "$fullname.txt");

		foreach my $worksheet (@{$oBook->{Worksheet}}) {
			for (my $iR = $worksheet->{MinRow} ;
					defined $worksheet->{MaxRow} && $iR <= $worksheet->{MaxRow};
					$iR++) {
				for (my $iC = $worksheet->{MinCol} ;	        	
						defined $worksheet->{MaxCol} && $iC <= $worksheet->{MaxCol} ; 
						$iC++) {
					my $cell = $worksheet->{Cells}[$iR][$iC];
					my $fieldinfo = ($cell) ? $cell->Value : "";
					$fieldinfo =~ tr/0-9//cd;
					print XDAT "$fieldinfo\n" if ($fieldinfo =~ /\d{10}/);
				}
			}
		}
		close(XDAT);	

		convert("$fullname.txt", $base, $dnc, $custdnc, $mobilescrub, $data);
	} else {
		$data->{'ErrStr'} = " $base did not have a recognized file type";
	}
}


# # # # # # # # #

mkdir('/tmp/LoadLeads') unless (-d '/tmp/LoadLeads');

$dbh = DialerUtils::db_connect();
$sbn2 = DialerUtils::sbn2_connect();
$r = initialize Rates(1);

# open the log file
open (LOG, '>>', '/var/log/LoadLeads.log') or die "cannot open log file: $!";
my $old_fh = select(LOG); $| = 1; select($old_fh); # unbufferd io on the log
flog('STARTED', 'hello');

while ($running == 1) {

	# find the smallest leads file to process
	my $dsz = -1;
	my $qitem = '';
	my $qjob = 'unknown';
	my $QDIR;
	if (! opendir($QDIR, '/dialer/projects/workqueue')) {
		flog('FATAL', "failed to open queue dir: $!");
		die "failed to open qdir: $!";
	}

	my $qcount = 0;
	my $qsize = 0;
	for my $ent (readdir($QDIR)) {
		next unless $ent =~ /^LoadLeads-JSON-(.*)/;
		my $job = $1;
		$qcount++;
    
		my $sz = (stat("/dialer/projects/workqueue/LoadLeads-DATA-$job"))[7];
		$qsize += $sz;

		if (($dsz == -1) || ($sz < $dsz)) {
			$dsz = $sz;
			$qitem = $ent;
			$qjob = $job;
		}
	}
	closedir $QDIR;

	if ($qitem eq '') { # nothing in the queue
		$dbh->disconnect;
		$sbn2->disconnect;
		flog('DEBUG', "Nothing to do sleeping $sleep seconds");
		sleep $sleep;
		flog('DEBUG', "woken up");
		$dbh = DialerUtils::db_connect();
		$sbn2 = DialerUtils::sbn2_connect();
		next;
	}
	
	my $est = int($qsize / 11);
	flog('QUEUE', "Queue has $qcount files with approximately $est numbers in total");

	$est = int($dsz / 11);
	flog('DEBUG', "processing entry: $qitem ($dsz bytes, $est estimated nums)");

	# read the json
	my $jtxt = `cat /dialer/projects/workqueue/$qitem`;
	my $data = JSON::from_json($jtxt);
	unlink("/dialer/projects/workqueue/LoadLeads-JSON-$qjob");
	$data->{'JobId'} = $qjob;

	do_numfile($data);

	unlink("/dialer/projects/workqueue/LoadLeads-DATA-$qjob");

}

$dbh->disconnect;
$sbn2->disconnect;

flog('TERMINATED', 'good bye');
close LOG;
