#!/usr/bin/perl

use strict;
use warnings FATAL => 'all';
use Text::CSV_XS;

use lib '/home/grant/H3/www/perl';
use DialerUtils;
$|=1;

my $running = 1;
my $csv = Text::CSV_XS->new({ binary => 1 });

sub Exit {
	print "\nsignal caught: stopping\n\n";
	$running = 0;
}

$SIG{TERM} = \&Exit;# kill
$SIG{INT}  = \&Exit;# ctrl-c
my $dbh = DialerUtils::db_connect(); # connect to the database

sub numfile_headers {

	# for numberfiles ending in .csv, look for exemplar row
	# in the projectnumbers and use it to build the headers

	print "Processing numberfiles to make headers\n";

	my $sth = $dbh->prepare('update numberfiles 
		set NF_ColumnHeadings = ? where NF_FileNumber = ?');

	my $nf = $dbh->selectall_arrayref(
				"select * from numberfiles where instr(NF_FileName,'.csv') > 0",
				{ Slice => {} });

	for my $nfrow (@$nf) {
		next unless $nfrow->{'NF_FileName'} =~ /\.csv$/;

		print "[" . $nfrow->{'NF_Project'} . "] " .
			$nfrow->{'NF_FileName'} . ": ";

		# check that $tbl exists 
		my $res = $dbh->selectrow_hashref("show table status 
			where name = 'projectnumbers_" . $nfrow->{'NF_Project'} . "'");

		if ((! defined($res)) || (! defined($res->{'Name'}))) {
			print "no projecnumbers file for project.\n";
			next;
		}

		my $pn = $dbh->selectrow_hashref("select * from 
			projectnumbers_" .  $nfrow->{'NF_Project'} .
			", popdata where PN_PhoneNumber = PD_Phone and
			PN_FileNumber = " . $nfrow->{'NF_FileNumber'} . 
			" limit 1", { Slice => {}});

		if (defined($pn->{'PD_Data'})) {
			# extract the headings
			if ($csv->parse($pn->{'PD_Data'})) {
				my @vals = $csv->fields();
				my $h = 0;
				my $hdrs;
				for my $v (@vals) {
					if ($h % 2 == 0) {
						$hdrs .= ',' if defined($hdrs);
						$hdrs .= "\"$v\"";
					}
					$h++;
				}
				$sth->execute($hdrs, $nfrow->{'NF_FileNumber'});

				print "$hdrs\n";
			} else {
				print "failed to parse the data!\n";
			}			
		} else {
			print "no exemplar found!\n";
		}
	}

}

sub popdata {

	# should run after headers are taken into numberfiles
	# fixes the data and inserts into popdataFIXED;

	my $sth = $dbh->prepare('insert into popdataFIXED 
		(PD_Project, PD_Phone, PD_Data) values (?, ?, ?)');

	my $pd = $dbh->selectall_arrayref(
				"select * from popdata",
				{ Slice => {} });

	for my $pdrow (@$pd) {

		my ($PD_Project, $PD_Phone, $PD_Data) = (
			$pdrow->{'PD_Project'},
			$pdrow->{'PD_Phone'},
			$pdrow->{'PD_Data'}
			);

		# reformat
		if ($csv->parse($PD_Data)) {
			my @vals = $csv->fields();
			my $h = 0;
			my $fix;
			for my $v (@vals) {
				if ($h % 2 == 1) {
					$fix .= ',' if defined($fix);
					$fix .= "\"$v\"";
				} 
				$h++;
			}
			$PD_Data = $fix;
		}

		$sth->execute($PD_Project,$PD_Phone,$PD_Data);
	}
}

##### Main

numfile_headers();
popdata();

my $res = $dbh->selectall_arrayref(
	"show table status where name like 'projectnumbers_%'",
	{ Slice => {} });

my $sofar = 0;
my $togo = scalar(@$res);

TABLE: for my $tr (@$res) {
	my $tblname = $tr->{'Name'};
	my $pjnum = $tblname;
	$pjnum =~ s/^projectnumbers_//;

	$sofar++;

	# get some background info
	my $info = $dbh->selectrow_hashref("select * from project, customer
		where PJ_CustNumber = CO_Number and PJ_Number = $pjnum");
	if (! defined($info->{'PJ_Number'})) {
		die "projectnumbers for project $pjnum has no info!\n";
	}
	my $desc = "Project $pjnum (" . $info->{'PJ_Description'} 
		. ") for customer " . $info->{'CO_Number'} . " (" 
		. $info->{'CO_Name'} . ")";

	printf "doing %4d of %d : %0.1f%% done [%s]\n", $sofar, $togo, 100*$sofar/$togo, $desc;

	# attempt to detect the change
	if (1) {
		my $d = $dbh->selectall_arrayref(
			"describe $tblname",
			{ Slice => {} });

		for my $fld (@$d) {
			if ($fld->{'Field'} eq 'PN_Disposition') {
				print "SKIP: $tblname Already has the change\n";
				next TABLE;
			}
		}
	}

	# execute the sql
	my @sql;
	push @sql, "delete from $tblname where PN_Status = 'X'";
	push @sql, "alter table $tblname add column PN_Disposition integer not null default 0, add column PN_CallResult char(2), add column PN_CallDT datetime, add column PN_Duration integer, add column PN_SurveyResults varchar(64), add column PN_DoNotCall char(1) not null default 'N', add column PN_Dialer char(4), add column PN_SysInfo varchar(64), add column PN_Agent integer, add column PN_Popdata text, add column PN_Notes text, drop column PN_RedialAfter, drop column PN_Dialcount";
	push @sql, "update $tblname, popdataFIXED set PN_Popdata = PD_Data where PN_PhoneNumber = PD_Phone and PD_Project = $pjnum";

	for my $s (@sql) {
		print "EXEC: $s\n";
		my $aff = $dbh->do($s) || print "PROBLEM: " . $dbh->errstr . "\n";
		print "$aff rows affected\n";
	}

	last unless $running == 1;

}

$dbh->disconnect;


