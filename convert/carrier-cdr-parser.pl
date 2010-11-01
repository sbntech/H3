#!/usr/bin/perl

use strict;
use warnings FATAL => 'all';
use lib '/home/grant/H3/www/perl/';
use DialerUtils;
use lib '/home/grant/H3/convert/npanxx-data/';
use Rates;
use DateTime;
use JSON;

$| = 1; # unbuffered output
my $LOCALDIR='/home/grant/carrier-cdr';
my $RESULTSDIR = "$LOCALDIR/results";
my $OURRESULTSDIR = '/home/grant/cdr-summaries';
my @SUMMARYattrs = ('Count', 'Duration', 'IntrastateCount', 'CarrierCost',
'Duration-Under7', 'Duration-Over180', 'Duration-Over2000', 'Duration-Over3600');

my $callType = $ARGV[0];
die "need a callType" unless defined $callType;
die "$OURRESULTSDIR does not exitst" unless -d $OURRESULTSDIR;

my %projRates; # $projRates{$pjid}

my $dbh;
my $r;

sub cdr_print {
	my $cdr = shift;
	print 
		$cdr->{'sbn_date'} . ',' .
		$cdr->{'sbn_time'} . ',' .
		$cdr->{'sbn_duration'} . ',' .
		$cdr->{'sbn_called'} . ',' .
		$cdr->{'sbn_cost'} . ',' .
		$cdr->{'sbn_i'} . ',' .
		$cdr->{'State Called'} .
		"\n"
}

sub cdr_dump {
	my $cdr = shift;

	for my $k (sort keys %$cdr) {
		my $val = $cdr->{$k};

		if (defined($val)) {
			printf '%-40s', $k;
			print ": $val\n";
		}
	}
}

sub make_summary_file {
	my $rdir = shift;
	my $counts = shift;
	my $phones = shift;

	my $characteristicDate; # used to sequence the dirs
	my $cnt = 0;

	# write out the daily amounts
	open SUMM, '>', "$rdir/summary.txt" or die "opening failed: $!";
	for my $d (keys %$counts) {

		if ($counts->{$d}{'Count'} > $cnt) {
			$cnt = $counts->{$d}{'Count'};
			$characteristicDate = $d;
		}
		print SUMM "$d";
		for my $t (@SUMMARYattrs) {
			my $val = $counts->{$d}{$t};
			$val = 0 unless defined($val);
			print SUMM " $val";
		}
		if ($counts->{$d}{'Duration'} > 0) {
			my $cave = (60 * $counts->{$d}{'CarrierCost'}) / $counts->{$d}{'Duration'};
			print SUMM " $cave";
		} else {
			print SUMM " 0.0";
		}
		print SUMM "\n";
	}
	close SUMM;

	open PHONES, '>', "$rdir/phones.txt" or die "open of phones failed: $!"; 
	for my $num (keys %$phones) {
		print PHONES "$num\t" . $phones->{$num} . "\n";
	}
	close PHONES;

	open JFILE, '>', "$rdir/summary.json" or die "opening failed: $!";
	print JFILE JSON::to_json($counts);
	close JFILE;

	system("echo $characteristicDate > $rdir/CharacteristicDate");
	system("touch $rdir/Completed");
}

sub csv_from_json {

	my $fname = shift;

	my $jtxt = `cat $fname`;
	my $counts = JSON::from_json($jtxt);

	my @colnames;
	my $rows;

	for my $k (keys %$counts) {
		if (! defined($rows)) {
			@colnames = keys %{$counts->{$k}};
		}

		$rows .= "$k";

		for my $col (@colnames) {
			my $val = $counts->{$k}{$col};
			$val = "" unless defined $val;
			$rows .= ",$val";
		}
		$rows .= "\n";
		
	}
	
	# headings...
	print "Date";
	map { print ",$_"; } @colnames;
	print "\n$rows";

}

sub count_cdr {
	my $carrChar = shift;
	my $counts = shift;
	my $cdr = shift;
	my $fcount = shift;
	my $phones = shift;

	my $dur = $cdr->{'sbn_duration'};

	$counts->{$cdr->{'sbn_date'}}{'Count'}++;
	$counts->{$cdr->{'sbn_date'}}{'Duration'} += $dur;
	$counts->{$cdr->{'sbn_date'}}{'CarrierCost'} += $cdr->{'sbn_cost'};
	if ($cdr->{'sbn_i'} eq 'intra') {
		$counts->{$cdr->{'sbn_date'}}{'IntrastateCount'}++ 
	} else {
		$phones->{$cdr->{'sbn_called'}} = $cdr->{'sbn_carrier_rate'};
	}

	if ($dur > 3600) {
		$counts->{$cdr->{'sbn_date'}}{'Duration-Over3600'}++;
	} elsif ($dur > 2000) {
		$counts->{$cdr->{'sbn_date'}}{'Duration-Over2000'}++;
	} elsif ($dur > 180) {
		$counts->{$cdr->{'sbn_date'}}{'Duration-Over180'}++;
	} elsif ($dur < 7) {
		$counts->{$cdr->{'sbn_date'}}{'Duration-Under7'}++;
	}

	my $ac = substr($cdr->{'sbn_called'},0,3);
	if (($ac == 204) or ($ac == 289) or ($ac == 306) or ($ac == 403) or ($ac == 416) or ($ac == 418) or ($ac == 450) or ($ac == 506) or ($ac == 514) or ($ac == 519) or ($ac == 604) or ($ac == 613) or ($ac == 647) or ($ac == 705) or ($ac == 709) or ($ac == 778) or ($ac == 780) or ($ac == 807) or ($ac == 819) or ($ac == 867) or ($ac == 902) or ($ac == 905)) {
		# canada
		$counts->{$cdr->{'sbn_date'}}{'Canada'}++;
	}


	$$fcount++;
	if ($$fcount % 10000 == 0) {
		print ".";
		print ">\n" if ($$fcount % 1000000 == 0);
	}
}

sub results_needed {
	my $fname = shift;

	my $base = $fname; 
	$base =~ s/.home.grant.carrier-cdr.(.*)$/$1/;
	$base =~ tr/\//_/;
	my $rdir = "$RESULTSDIR/$base";
	
	if (-f "$rdir/Completed") {
		print "skipping $base, already done\n";
		return undef;
	} else {
		system("rm -rf $rdir");
		mkdir $rdir;
		print "reading $fname, summarizing into $rdir\n";
		return $rdir;
	}

}

sub sbn_Read {
	my $DAY = shift;
	my $fday = substr($DAY,0,4) . '-' . substr($DAY,4,2) . '-' . substr($DAY,6,2);

	# each file gets summarized into $OURRESULTSDIR/$DAY/...
	my $rdir = "$OURRESULTSDIR/$DAY";
	if (-f "$rdir/Completed") {
		print "skipping $DAY, already done\n";
		return;
	} else {
		system("rm -rf $rdir");
		mkdir $rdir;
	}

	print "reading sbn cdrs for $DAY, summarizing into $rdir ...\n";
	my %dayStats;	# $dayStats{CARR|Total}{Count|Duration|...}
	
	foreach my $file (`find /dialer/projects -wholename "/dialer/projects/*/cdr/cdr-$fday.zip"`) {
		chomp $file;
		my $pjid = $file;
		$pjid =~ s/.*_(\d*)\/cdr\/cdr-\d\d\d\d-\d\d-\d\d\.zip/$1/;

		print "$fday:  project $pjid ...\n";

		if (! open(DATA, "unzip -p '$file'|")) {
			die "Failed to open $file: $!";
		}

		while (my $line=<DATA>) {
			my $cdr = DialerUtils::sbncdr_parser($line);

			die "unparsable cdr $line" unless defined ($cdr);

			# determine the project's rate if needed
			if (!defined($projRates{$pjid})) {
				# lookup the rate ...
				# ... retrieve the project record
				my $p = $dbh->selectrow_hashref("select * from 
					project where PJ_Number = $pjid limit 1");
				if (! defined($p->{'PJ_Number'})) {
					die "unable to fetch project for $pjid on $DAY";
				}

				# ... retrieve the customer record
				my $cnum = $p->{'PJ_CustNumber'};
				my $c = $dbh->selectrow_hashref("select * from
					customer where CO_Number = $cnum limit 1");
				if (! defined($c->{'CO_Number'})) {
					die "unable to fetch customer record for $pjid on $DAY" .
						" using customer number $cnum";
				}

				if ($c->{'CO_ResNumber'} == 1) {
					$projRates{$pjid} = $c->{'CO_Rate'};
				} else {
					# ... retrieve the reseller record
					my $rnum = $c->{'CO_ResNumber'};
					my $r = $dbh->selectrow_hashref("select * from
						reseller where RS_Number = $rnum limit 1");
					if (! defined($r->{'RS_Number'})) {
						die "unable to fetch reseller record for $pjid on $DAY" .
							" using reseller number $rnum";
					}
					$projRates{$pjid} = $r->{'RS_Rate'};
					my $df = $r->{'RS_DistribFactor'};
					if ((defined($df)) && ($df > 1)) {
						$projRates{$pjid} = $r->{'RS_Rate'} * $df;
					}
				}
			}

			# determine if it counts as a connect 
			my $conn = 1;
			if ($cdr->{'Dialer'} eq 'COLD') {
				$conn = 0 if ($cdr->{'Disposition'} eq 'AC');
				$conn = 0 if ($cdr->{'Disposition'} eq 'AS') &&
							 ($cdr->{'CallSetup'} ne 'Standby-OFF');
			}

			# billing/rating
			my $rdur = 0;
			if ($cdr->{'Duration'} > 0) {
				my $m = 0;
				if ($cdr->{'Duration'} % 6 > 0) {
					$m = 6 - ($cdr->{'Duration'} % 6);
				}
				$rdur = $cdr->{'Duration'} + $m;

				# determine the revenue
				my $sbnRevenue = ($rdur / 60) * $projRates{$pjid};

				# determine the cost from NpaNxx table
				my $rl = $r->lookup_number($cdr->{'CalledNumber'});
				my $sbnRate = $rl->{'Rates'}{$cdr->{'CarrierCode'}};
				my $sbnCost = 0;
				if (defined($sbnRate)) {
					$sbnCost = ($rdur / 60) * $sbnRate;
				}

				# store the "day" stats
				$dayStats{$cdr->{'CarrierCode'}}{'Connects'} += $conn;
				$dayStats{$cdr->{'CarrierCode'}}{'Duration'} += $rdur;
				$dayStats{$cdr->{'CarrierCode'}}{'Revenue'} += $sbnRevenue;
				$dayStats{$cdr->{'CarrierCode'}}{'Cost'} += $sbnCost;

				$dayStats{'TOTAL'}{'Connects'} += $conn;
				$dayStats{'TOTAL'}{'Duration'} += $rdur;
				$dayStats{'TOTAL'}{'Revenue'} += $sbnRevenue;
				$dayStats{'TOTAL'}{'Cost'} += $sbnCost;
			} else {
				# non-connect stats
				$dayStats{$cdr->{'CarrierCode'}}{'NonConnects'} += $conn;
				$dayStats{'TOTAL'}{'NonConnects'} += $conn;
			}

		}
		close(DATA);
	}

	# write the dayStats
	open OUT, '>', "$rdir/dayStats.json" or die "failed to open: $!";
	print OUT JSON::to_json(\%dayStats, {pretty => 1});
	close OUT;

	system("touch $rdir/Completed");

}

sub sbn_ReadRaw {

	print "reading sbn\n";

	my $now = DateTime->now(time_zone => 'America/New_York'); 
	my $dt  = DateTime->now(time_zone => 'America/New_York'); 
	$dt->subtract_duration(DateTime::Duration->new(weeks => 6)); 
	while (DateTime->compare($dt, $now) < 0) {
		sbn_Read($dt->ymd(''));
		$dt = $dt->add(days => 1);
	}

}

sub do_perc {
	my $val = shift;
	my $total = shift;

	$val = 0 unless defined $val;
	my $perc = '';
	if ((defined($total)) && ($total > 0)) {
		$perc = sprintf('%0.1f%%', 100 * $val / $total);
	}
	return "$val,$perc,";
}

sub sbn_summarize {

	my %ss; # spreadsheet  ss{'2009-01-01'}{Mins|Conns|Cost|
	# read the CarrierSummary.json file
	my $jtxt = `cat $OURRESULTSDIR/CarrierSummary.json`;
	my $carrSumm = JSON::from_json($jtxt);

	my $now = DateTime->now(time_zone => 'America/New_York'); 
	my $nowstr = $now->ymd . ' ' . $now->hms;
	my $dt  = DateTime->new(year => 2009, month => 10, day => 1,
	  	time_zone  => 'America/New_York');

	my $bigcsv = 
		"Produced: $nowstr\n" . 
		"Date," . 
		'Mins-Qwest, Mins-GCNS, Mins-Gblx, Mins-MB, Mins-Mass, Mins-Mike,' .
		'Conns-Qwest, Conns-GCNS, Conns-Gblx, Conns-MB, Conns-Mass, Conns-Mike,' .
		'Cost-Qwest, Cost-GCNS, Cost-Gblx, Cost-MB, Cost-Mass, Cost-Mike' .
		"\n";

	while (DateTime->compare($dt, $now) < 0) {
		my $ymd = $dt->ymd('');
		my $sbndir = "$OURRESULTSDIR/$ymd";
		if ( -d $sbndir ) {
			print "doing $sbndir\n";

			# Column: date
			$bigcsv .= "$ymd,";

			# read dayStats
			$jtxt = `cat $sbndir/dayStats.json`;
			my $dayStats = JSON::from_json($jtxt);

			# Columns: minutes
			for my $carr ('A', 'B', 'F', 'G', 'H', 'Z') { 
				my $dur = $dayStats->{$carr}{'Duration'};
				$dur = (defined($dur)) ? $dur /60 : 0;
				if ($carr eq 'F') {
					$dur = $dur / 1.04;
				} else {
					$dur = $dur / 1.07;
				}
				$bigcsv .= int($dur) . ',';
			}

			# Columns: connects
			for my $carr ('A', 'B', 'F', 'G', 'H', 'Z') { 
				my $conn = $dayStats->{$carr}{'Connects'};
				$conn = 0 unless defined($conn);
				$bigcsv .= int($conn) . ',';
			}

			# Columns: cost
			for my $carr ('A', 'B', 'F', 'G', 'H', 'Z') { 
				my $cost = $dayStats->{$carr}{'Cost'};
				$cost = 0 unless defined($cost);
				$bigcsv .= sprintf('%0.2f,', $cost);
			}

			$bigcsv .= "\n";
		}
		$dt = $dt->add(days => 1);
	}

	open OUT, '>', "/dialer/website/cdr-summary/cdr-summary.csv" or die "opening failed: $!";
	print OUT $bigcsv;
	close OUT;
}

sub accumulate {
	my $carrChar = shift;
	my $res = shift;
	my $rdir = shift;


	if (open SUMM, '<', "$rdir/summary.txt") {
		while (<SUMM>) {
			my @vals = split; # splits on whitespace by default
			my $key = $vals[0];
			my $i = 0;
			for my $t (@SUMMARYattrs) {
				$i++; 
				$res->{$key}{$t} += $vals[$i];
			}
		}
		close SUMM;
	} else {
		print "(missing summary.txt in $rdir)\n";
	}

}

sub make_phones {

	my $phload = "$RESULTSDIR/phones.load";
	unlink($phload) if -f $phload;

	print "making the phones table\n";

	# read all the result directories and the first date in summary.txt, also determine carrier char
	my $inlist = `find $RESULTSDIR -type d -wholename '*/results/*'`;
	my @dirs;
	while (length($inlist) > 0) {
		my $len = index($inlist, "\n");
		my $dirname = substr($inlist, 0, $len);
		$inlist = substr($inlist, $len + 1);

		# skip bbcom - we don't use phones for them
		next if $dirname =~ /bbcom/;

		# read the CharacteristicDate
		if (open CHARDT, '<', "$dirname/CharacteristicDate") {
			my $dt = <CHARDT>;
			close CHARDT;
			if ($dt =~ /^(20\d{6})/) {
				push @dirs, { DirName => $dirname, DirDate => $1 };
			} else {
				print "($dirname/CharacteristicDate does not have a parable date)\n";
			}
		} else {
			print "(missing CharacteristicDate in $dirname)\n";
		}
	}

	# sort the directories in date sequence
   	my @sorteddirs = sort { $a->{DirDate} <=> $b->{DirDate} } @dirs;
	my %carrIndex = ( 'gblx' => 0, 'qwes' => 1);

	my $acdr = 0;

	# break it up into multiple scans
	for (my $i = 0; $i < 10; $i++) {
		my $tcdr = 0;
		my $fcdr = 0;
		my $ucdr = 0;
		print "$i: ";
		my %phones; 
		for my $d (@sorteddirs) {
			my $dir = $d->{DirName};
			$dir =~ /.home.grant..*\/(.{4}).*/;
			my $carrIdx = $carrIndex{$1};
			die "$dir - cannot determine carrier" unless defined $carrIdx;

			open PHONES, '<', "$dir/phones.txt" or die "open of $dir/phones failed: $!"; 
			while (<PHONES>) {
				if (/(\d{9})(\d)\s*([\.0-9]*)\n/) {
					$tcdr++;
					next unless ($2 == $i);
					$fcdr++;
					my ($num, $rate) = ("$1$2", $3);
					$phones{$num}->[$carrIdx] = $rate;
				} else {
					die "unparsable $dir/phones.txt line: $_\n";
				}
			}
			close PHONES;

			print ".";
			# print $d->{DirDate} . ' ' . $d->{DirName} . "\n";
		}
		print " writing ... ";

		open PHLOAD, '>>', $phload or die "open of $phload failed: $!";
		for my $num (keys %phones) {
			print PHLOAD "$num\t";
			$ucdr++;
			$acdr++;

			for (my $k = 0; $k < 2; $k++) {
				if (defined($phones{$num}->[$k])) {
					print PHLOAD $phones{$num}->[$k] . "\t";
				} else {
					print PHLOAD "\\N\t";
				}
			}
			print PHLOAD "\n";
		}
		close PHLOAD;
		print "ok ($fcdr cdrs used out of $tcdr for run-$i, giving $ucdr unique phone numbers)\n";
	}
	print "we have $acdr total unique phone numbers\n";

	# load phones.load into phones - then rebuild index
	print "loading phones table\n";
	system("mv $phload /var/lib/mysql/sbn2/phones.tmp");
	my $sbn2 = DBI->connect("DBI:mysql:sbn2;host=localhost", 'root', 'sbntele') || die("Cannot Connect to database: $!");
	$sbn2->do("truncate table phones");
	$sbn2->do("alter table phones drop primary key");
	$sbn2->do("load data infile 'phones.tmp' into table phones (PH_Number, PH_CarrierF, PH_CarrierA)");
	my $res = $sbn2->selectrow_hashref("select count(*) as RowCount from phones");
	my $phcount = $res->{'RowCount'};
	print "phones has $phcount rows\n";
	$sbn2->do("alter table phones add primary key(PH_Number)");
	$sbn2->disconnect;
	system("mv /var/lib/mysql/sbn2/phones.tmp $phload");
}

sub summarize {

	my %summaries = ( 'gblx' => {}, 'qwest' => {}, 'bbcom' => {}); # eg: $summaries{gblx}{$date}

	print "accumulating...\n";
	my $ac = 0;

	# global crossing
	my $inlist = `find $RESULTSDIR -name 'gblx_*' -type d | sort`;
	while (length($inlist) > 0) {
		my $len = index($inlist, "\n");
		my $dirname = substr($inlist, 0, $len);
		$inlist = substr($inlist, $len + 1);

		$ac++;
		accumulate('F', $summaries{gblx}, $dirname);
	}
	print "accumulated $ac gblx directories\n";
	$ac = 0;

	# qwest
	$inlist = `find $RESULTSDIR -name 'qwest_*' -type d | sort`;
	while (length($inlist) > 0) {
		my $len = index($inlist, "\n");
		my $dirname = substr($inlist, 0, $len);
		$inlist = substr($inlist, $len + 1);

		$ac++;
		accumulate('A', $summaries{qwest}, $dirname);
	}
	print "accumulated $ac qwest directories\n";
	$ac = 0;

	# bbcom
	$inlist = `find $RESULTSDIR -name 'bbcom_*' -type d | sort`;
	while (length($inlist) > 0) {
		my $len = index($inlist, "\n");
		my $dirname = substr($inlist, 0, $len);
		$inlist = substr($inlist, $len + 1);

		$ac++;
		accumulate('D', $summaries{bbcom}, $dirname);
	}
	print "accumulated $ac bbcom directories\n";

	print "summarizing ...\n";

	# write out the big summary
	my $summf = "$RESULTSDIR/CarrierSummary.json";
	open SUMM, '>', $summf or die "opening $summf failed: $!";
	print SUMM JSON::to_json(\%summaries, {pretty => 1});
	close SUMM;
	system("scp $summf app.quickdials.com:/home/grant/cdr-summaries/");
}


######################################################################

$r = initialize Rates(1);

if (( -d '/dialer/projects/_1/cdr' ) && ($callType eq 'quickdials')) {
	# running on b1-ap so we are doing our cdrs
	$dbh = DialerUtils::db_connect();
	sbn_ReadRaw();
	sbn_summarize();
	$dbh->disconnect;
} else {
	if ($callType eq 'jrep') {
		csv_from_json($ARGV[1]);
	}

	summarize() if ($callType eq 'summary');
	make_phones() if ($callType eq 'phones');
}

