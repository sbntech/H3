#!/usr/bin/perl

package ResellerCIDList;

use strict;
use warnings;

use Apache2::Const qw(:methods :common);

sub add_new {
	my $dbh = shift;
	my $data = shift;

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
			$values .= "('" . $data->{'RS_Number'} . "','$n', now())";
		}
	}
		
	my $sql = "insert ignore into rescallerid (RC_Reseller, RC_CallerId, RC_CreatedOn)
		values $values";

	$dbh->do($sql) if length($values) > 0;
	
	delete $data->{'RC_CallerId'};
}

sub del_cid {
	my $dbh = shift;
	my $data = shift;


	my $c = $dbh->selectrow_hashref("select count(*) as UsedCount 
		from custcallerid, customer where CC_CallerId = '" . $data->{'RC_CallerId'} . 
		"' and CO_Number = CC_Customer and CO_ResNumber = '" . $data->{'RS_Number'} . "'");
	my $UsedCount = (defined($c->{'UsedCount'})) ? $c->{'UsedCount'} : 0;
	
	if ($UsedCount > 0) {
		$data->{'Processing_Error'} = "Attempt to delete " . $data->{'RC_CallerId'} . 
			" failed because it is allowed on $UsedCount customers";
		return;
	} else {
		my $sql = "delete from rescallerid 
			where RC_CallerId = '" . $data->{'RC_CallerId'} . 
			"' and RC_Reseller = '" . $data->{'RS_Number'} . "' limit 1";
		$dbh->do($sql);
		
		print STDERR "Deleted reseller" . $data->{'RS_Number'} . " caller id: " . $data->{'RC_CallerId'} . "\n";
	}

	delete $data->{'RC_CallerId'};
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
					} elsif ($data->{'X_Method'} eq 'Delete') {
						# delete one
						del_cid($dbh, $data);
					}
				}

				$data->{'X_Sql'} = "select RC_Reseller, RC_CallerId, RC_CreatedOn,
					(select count(*) from custcallerid, customer 
						where CO_Number = CC_Customer and CO_ResNumber = RC_Reseller 
						and CC_CallerId = RC_CallerId) as UsedCount
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
