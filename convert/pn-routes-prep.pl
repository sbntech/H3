#!/usr/bin/perl

use strict;
use warnings FATAL => 'all';

use lib '/home/grant/H3/www/perl';
use DialerUtils;
use DBI;
my $dbh = DialerUtils::db_connect(); # connect to the database

$dbh->do("drop table if exists temp_routing");
$dbh->do("create table temp_routing (
	TR_Project int(11) not null,
	TR_Flag char(1),
	TR_Seq int(11) not null default 0,
	TR_Rows int(11) not null default 0,
	PRIMARY KEY(TR_Project))");


# populate temp_routing
my $res = $dbh->selectall_arrayref(
	"show table status where name like 'projectnumbers_%'",
	{ Slice => {} });
for my $tr (@$res) {
	my $tblname = $tr->{'Name'};
	my $rowcount = $tr->{'Rows'};

	next if $rowcount == 0; # happens after leads deleted
	my $pjnum = $tblname;
	$pjnum =~ s/^projectnumbers_//;

	my $ci = $dbh->selectrow_hashref("select PJ_CustNumber, CO_ResNumber, PJ_Description, PJ_timeleft, CO_Name,
		(select max(unix_timestamp(RE_Date)) from report where RE_Project = $pjnum) as SortSeq from project, customer 
		where PJ_CustNumber = CO_Number and PJ_Number = $pjnum limit 1");

	if (! defined($ci->{'PJ_CustNumber'})) {
		print "Failed to read row for project $pjnum\n";
		next;
	}

	if (defined($ci->{'SortSeq'})) {
		if ($ci->{'PJ_timeleft'} eq 'Running') {
			$ci->{'SortSeq'} = time();
		}

		$dbh->do("insert into temp_routing values('$pjnum',null,'" . $ci->{'SortSeq'} . "',$rowcount)");
	}
}


$dbh->disconnect;
