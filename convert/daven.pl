#!/usr/bin/perl

# special processing for daven

use strict;
use warnings;
use DBI;
use Net::SMTP;
use lib '/home/grant/sbn-git/www/perl/';
use DialerUtils;

my $daven = 3; # reseller number
my $otherreseller = 71 ; # reseller name: prospect
my $dbh = DialerUtils::db_connect();

# -------------------------------------------------------------------------------------------------
# check for recordings longer than 25 seconds
my $reclen = 25;
my %embody;

my $res = $dbh->selectall_arrayref("select PJ_Number, PJ_CustNumber, PJ_Description, CO_Name, CO_ResNumber 
	from project, customer 
	where PJ_CustNumber = CO_Number and CO_BillingType != 'T' and 
	(CO_ResNumber = $daven or CO_ResNumber = $otherreseller) and 
	exists (select 'X' from report where RE_Project = PJ_Number and RE_Date = current_date())", 
	{ Slice => {} });

for my $row (@$res) {
	for my $fn ('live', 'machine') {
		my ($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size,$atime,$mtime,$ctime,$blksize,$blocks) = 
			stat('/dialer/projects/_' . $row->{'PJ_Number'} . "/voiceprompts/$fn.vox");
		if (defined($size)) {
			my $voxdur = int($size / 8000);
			if ($voxdur > $reclen) {
				$embody{$row->{'CO_ResNumber'}} .=
					'Customer: ' . $row->{'CO_Name'} . ' (' . $row->{'PJ_CustNumber'} . 
					') in ' . $row->{'PJ_Description'} . ' (' . $row->{'PJ_Number'} . 
					") has $fn.vox lasting $voxdur seconds\n";
			}
		}
	}
}

for my $rk (keys %embody) {
	my $To = 'support@xmvoice.com';
	$To = 'leadtoolbox@gmail.com' if ($rk == $otherreseller);

	if (length($embody{$rk}) > 0) {
		print "$rk:\n" . $embody{$rk} . "\n";
		my $em = "To: $To\nFrom: \"Support\"<no-reply\@sbndials.com\nSubject: Messages exceeding $reclen seconds\n\n"
					. $embody{$rk};

		my $smtp = Net::SMTP->new("10.9.2.1", Timeout => 60, Debug => 0) or die "failed to smtp: $!";
		$smtp->mail('no-reply@sbndials.com');
		$smtp->to($To);
		$smtp->data();
		$smtp->datasend($em);
		$smtp->dataend();
		$smtp->quit;
	}
}

$dbh->disconnect;
