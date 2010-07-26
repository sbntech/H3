#!/usr/bin/perl

package CustomerCIDList;

use strict;
use warnings;

use Apache2::Const qw(:methods :common);

sub allow_cid {
	my $dbh = shift;
	my $data = shift;

	# Check if the number belongs to the reseller
	my $check = $dbh->selectrow_hashref("select RC_CallerId
		from rescallerid where RC_CallerId = '" .
		$data->{'CC_CallerId'} . "' and RC_Reseller = '"
		. $data->{'ContextCustomer'}{'CO_ResNumber'} . "' limit 1");

	if (defined($check->{'RC_CallerId'})) {
		my $sql = "insert into custcallerid (CC_Customer, CC_CallerId, CC_CreatedOn)
		values ('" . $data->{'CO_Number'} . "','" . 
		$data->{'CC_CallerId'} . "', now())";

		$dbh->do($sql);
	} else {
		$data->{'Processing_Error'} = "Caller Id [" .
			$data->{'CC_CallerId'} . "] is not in the usable set.";
	}

}

sub disallow_cid {
	my $dbh = shift;
	my $data = shift;

	my $sql = "delete from custcallerid where CC_CallerId = '" . 
		$data->{'CC_CallerId'} . "' and CC_Customer = '" .
		$data->{'CO_Number'} . "'";

	$dbh->do($sql);

	my $pcnt = $dbh->do("update project set PJ_OrigPhoneNr = null where
			PJ_OrigPhoneNr = '" . $data->{'CC_CallerId'} . 
			"' and PJ_CustNumber = " . $data->{'CO_Number'});

	print STDERR "Disallowed customer "	. $data->{'CO_Number'} . 
		" caller id [" . $data->{'CC_CallerId'} . "]: $pcnt projects affected\n";

	delete $data->{'RC_CallerId'};
	delete $data->{'RC_DefaultFlag'};
}

sub handler {
	my $r = shift;

	my $req = Apache2::Request->new($r, 
		POST_MAX => 10*1024,
		DISABLE_UPLOADS => 1);

	my $dbh = DialerUtils::db_connect(); 
	my $data = DialerUtils::step_one($req, $dbh,
		$req->param->{'CO_Number'}, 0);

	if ((defined($data->{'ErrStr'})) && (length($data->{'ErrStr'}) > 0)) {
		$data->{'ErrStr'} .= "\nAuthorization failed";
	} elsif ($data->{'Z_CO_Permitted'} ne 'Yes') {
		$data->{'ErrStr'} .= " Not permitted on this customer";
	} elsif ($data->{'Session'}{'L_Level'} < 5) {
		$data->{'ErrStr'} = "Insufficient rights.";
	} else {
		if (defined($data->{'X_Method'})) {
			if ($data->{'X_Method'} eq 'Allow') {
				# adding a new one.
				allow_cid($dbh, $data);
			} elsif ($data->{'X_Method'} eq 'Disallow') {
				disallow_cid($dbh, $data);
			}
		}

		$data->{'X_AllowSql'} = "select CC_Customer, CC_CallerId, CC_CreatedOn
			from custcallerid where CC_Customer = " . $data->{'CO_Number'};
		my $res = $dbh->selectall_arrayref($data->{'X_AllowSql'}, { Slice => {} });
		$data->{'AllowedList'} = $res;

		$data->{'X_NotAllowSql'} = "select RC_CallerId from rescallerid where
			RC_Reseller = " . $data->{'ContextCustomer'}{'CO_ResNumber'} . " and RC_DefaultFlag = 'N' and 
			not exists(select 'x' from custcallerid where CC_CallerId = RC_CallerId and CC_Customer = " . $data->{'CO_Number'} . ")";
		$res = $dbh->selectall_arrayref($data->{'X_NotAllowSql'}, { Slice => {} });
		$data->{'NotAllowedList'} = $res;
	}
	$dbh->disconnect;

	# render the page
	$req->content_type('text/html');
	my $tt = Template->new(INCLUDE_PATH => '/dialer/www/perl')
		|| die $Template::ERROR, "\n";
	$tt->process('CustomerCIDList.tt2', $data) || die $tt->error(), "\n";

	return Apache2::Const::OK;
}
1;
