#!/usr/bin/perl

package ResellerCIDList;

use strict;
use warnings;

use Apache2::Const qw(:methods :common);

sub add_new {
	my $dbh = shift;
	my $data = shift;

	# normalize the flag
	my $def = ((defined($data->{'RC_DefaultFlag'})) && ($data->{'RC_DefaultFlag'} eq 'on')) ? 'Y' : 'N';
	$data->{'RC_DefaultFlag'} = $def;

	# validate the number 
	my $inlist = $data->{'RC_CallerId'};
	my $values = '';
	while (length($inlist) > 0) {
		my $len = index($inlist, "\n");
		my $num;
		if ($len < 0) {
			# eol not found
			if (length($inlist) > 0) {
				$num = $inlist;				
				$inlist = '';
			} else {
				last;
			}
		} else {
			$num = substr($inlist, 0, $len);
			$inlist = substr($inlist, $len + 1);
		}

		my $n = DialerUtils::north_american_phnumber($num);
		if (($n =~ /^\d{10}$/) && ($n !~ /^8(00|66|77|88|55|44|33|22)/)) {
			$values .= ',' if length($values) > 0;
			$values .= "('" . $data->{'RS_Number'} . "','$n','$def', now())";
		}
	}
		
	my $sql = "insert ignore into rescallerid (RC_Reseller, RC_CallerId, RC_DefaultFlag, RC_CreatedOn)
		values $values";

	$dbh->do($sql) if length($values) > 0;
	delete $data->{'RC_CallerId'};
	delete $data->{'RC_DefaultFlag'};

}

sub del_cid {
	my $dbh = shift;
	my $data = shift;

	my $sql = "delete from rescallerid 
		where RC_CallerId = '" . $data->{'RC_CallerId'} . 
			"' and RC_Reseller = '" . $data->{'RS_Number'} . "' limit 1";
	$dbh->do($sql);

	$sql = "select * from custcallerid, customer where CC_CallerId = '" . $data->{'RC_CallerId'} . 
		"' and CO_Number = CC_Customer and CO_ResNumber = '" . $data->{'RS_Number'} . "'";
	my $c = $dbh->selectall_arrayref($sql, { Slice => {} });
	my $logstr = "Deleted reseller" . $data->{'RS_Number'} . " caller id [" . $data->{'RC_CallerId'} . "], cascaded to customers:\n";

	for my $i (@$c) {
		$dbh->do("delete from custcallerid where CC_Customer = " . $i->{'CC_Customer'} . 
			" and CC_CallerId = '" . $data->{'RC_CallerId'} . "'");

		my $pcnt = $dbh->do("update project set PJ_OrigPhoneNr = null where
			PJ_OrigPhoneNr = '" . $data->{'RC_CallerId'} . 
			"' and PJ_CustNumber = " . $i->{'CC_Customer'});

		$logstr .= "    " . $i->{'CC_Customer'} . " - " . $i->{'CO_Name'} . 
			": $pcnt projects affected\n";
	}

	print STDERR $logstr;

	delete $data->{'RC_CallerId'};
	delete $data->{'RC_DefaultFlag'};
}

sub flip_default {
	my $dbh = shift;
	my $data = shift;

	my $sql = "update rescallerid 
		set RC_DefaultFlag = IF(RC_DefaultFlag = 'Y','N','Y')
		where RC_CallerId = '" . $data->{'RC_CallerId'} . 
			"' and RC_Reseller = '" . $data->{'RS_Number'} . "' limit 1";

	$dbh->do($sql);
	delete $data->{'RC_CallerId'};
	delete $data->{'RC_DefaultFlag'};
}

sub handler {
	my $r = shift;

	my $req = Apache2::Request->new($r, 
		POST_MAX => 10*1024,
		DISABLE_UPLOADS => 1);

	my $dbh = DialerUtils::db_connect(); 
	my $data = DialerUtils::step_one($req, $dbh, 0, 0);

	if ((defined($data->{'ErrStr'})) && (length($data->{'ErrStr'}) > 0)) {
		$data->{'ErrStr'} .= "\nAuthorization failed";
	} elsif ($data->{'Session'}{'L_Level'} != 6) {
		$data->{'ErrStr'} .= " Not authorized!";
	} else {
		# get reseller
		if ((defined($data->{'RS_Number'})) && ($data->{'RS_Number'} > 0)) {
			my $res = $dbh->selectrow_hashref(
				"select RS_Name from reseller 
				where RS_Number = " . $data->{'RS_Number'});

			if (defined($res->{'RS_Name'})) {
				$data->{'RS_Name'} = $res->{'RS_Name'};

				if (defined($data->{'X_Method'})) {
					if ($data->{'X_Method'} eq 'AddNew') {
						# adding a new one.
						add_new($dbh, $data);
					} elsif ($data->{'X_Method'} eq 'FlipDefault') {
						flip_default($dbh, $data);
					} elsif ($data->{'X_Method'} eq 'Delete') {
						# delete one
						del_cid($dbh, $data);
					}
				}

				$data->{'X_Sql'} = "select RC_Reseller, RC_CallerId, RC_DefaultFlag, RC_CreatedOn
					from rescallerid where RC_Reseller = " . $data->{'RS_Number'};
				$res = $dbh->selectall_arrayref($data->{'X_Sql'}, { Slice => {} });
				$data->{'List'} = $res;
			} else {
				$data->{'ErrStr'} = "Could not find reseller with RS_Number=" . $data->{'RS_Number'};
			}
		} else {
			$data->{'ErrStr'} = "Invalid RS_Number=" . $data->{'RS_Number'};
		}
	}
	$dbh->disconnect;

	# render the page
	$req->content_type('text/html');
	my $tt = Template->new(INCLUDE_PATH => '/dialer/www/perl')
		|| die $Template::ERROR, "\n";
	$tt->process('ResellerCIDList.tt2', $data) || die $tt->error(), "\n";

	return Apache2::Const::OK;
}
1;
