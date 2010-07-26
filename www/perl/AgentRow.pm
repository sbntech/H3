#!/usr/bin/perl

package AgentRow;

use strict;
use warnings;

use Apache2::Const qw(:methods :common);
use JSON;

sub required {
	my $data = shift;
	my $fld = shift;

	if (DialerUtils::is_blank_str($data->{$fld})) {
		$data->{$fld . '_ERROR'} = 'Required';
		return 0;
	} else {
		return 1;
	}
}

sub make_sql {
	my $data = shift;
	my $dbh = shift;

	my $valid = 1;
	my $uniqCheck = "";

	my @cols = ('AG_Password', 'AG_Name', 'AG_Email', 
		'AG_CallBack', 'AG_Status', 'AG_MustLogin', 'AG_Project');

	$valid = 0 if required($data,'AG_Password') == 0;
	$valid = 0 if required($data,'AG_Name') == 0;
	$valid = 0 if required($data,'AG_CallBack') == 0;
	$valid = 0 if required($data,'AG_Status') == 0;
	$valid = 0 if required($data,'AG_MustLogin') == 0;
	$valid = 0 if required($data,'AG_Project') == 0;

	# cleanse first
	for my $f (@cols) {
		if (defined($data->{$f})) {
			$data->{$f} =~ s/['"]//g;
			$data->{$f} =~ s/^\s*(.*)\s*$/$1/g; # trim
		}
	}

	# AG_Number
	my $agId = DialerUtils::make_an_int($data->{'AG_Number'});
	$data->{'AG_Number'} =  $agId;
	if ($agId == 0) {
		if ($data->{'X_Method'} eq 'Update') {
			$data->{'ErrStr'} = 'Agent number was missing for Update';
			return undef; # no point continuing, this is serious
		}
	} else {
		if ($data->{'X_Method'} eq 'Insert') {
			$data->{'ErrStr'} = 'Agent number cannot be provided for Insert';
			return undef; # no point continuing, this is serious
		}
		$uniqCheck = 'and AG_Number != ' . $data->{'AG_Number'};
	}

	# AG_Customer
	if ($data->{'X_Method'} eq 'Update') {
		my $old = $dbh->selectrow_hashref("select AG_Customer
			from agent where AG_Number = '" . $data->{'AG_Number'}
			. "'");
		if (!defined($old->{'AG_Customer'})) {
			$data->{'ErrStr'} = 'AG_Number is invalid';
			$valid = 0;
		} elsif ($old->{'AG_Customer'} != $data->{'CO_Number'}) {
			$data->{'ErrStr'} = 'Cannot change customer like this';
			$valid = 0;
		}
	} else {
		$data->{'AG_Customer'} = $data->{'ContextCustomer'}{'CO_Number'};
	}

	# AG_Name
	# check for uniqueness
	my $nameFind = $dbh->selectrow_hashref(
		"select count(*) as cnt from agent
		where AG_Name = '" . $data->{'AG_Name'} .
		"' $uniqCheck");

	if ($nameFind->{'cnt'} > 0) {
		$data->{'AG_Name_ERROR'} = 'Not unique';
		$valid = 0;
	}

	# AG_CallBack
	my $cb = DialerUtils::north_american_phnumber($data->{'AG_CallBack'});
	if ($cb =~ /^(800|888|866|877)\d{7}$/) {
		$data->{'AG_CallBack_ERROR'} = 'Cannot be toll free';
		$valid = 0;
	}
	if ($data->{'AG_CallBack'} !~ /^(\d{10}$|sip:.*@.*$)|call-in/) {
		$data->{'AG_CallBack_ERROR'} = 'Must be PSTN phone number or sip address or call-in';
		$valid = 0;
	}

	# AG_Status
	if (! DialerUtils::valid_values_str($data->{'AG_Status'}, 'A', 'B')) {
		$data->{'AG_Status_ERROR'} = 'Not a valid value';
		$valid = 0;
	}

	# AG_MustLogin
	if (! DialerUtils::valid_values_str($data->{'AG_MustLogin'}, 'Y', 'N')) {
		$data->{'AG_MustLogin_ERROR'} = 'Not a valid value';
		$valid = 0;
	}

	# AG_Project
	if ((defined($data->{'AG_Project'})) && 
		($data->{'AG_Project'} > 0)) {

		my $pj = $dbh->selectrow_hashref(
			"select PJ_CustNumber from project
			where PJ_Number = '" . $data->{'AG_Project'} .
			"' and PJ_Visible = 1");

		if ($pj->{'PJ_CustNumber'} != $data->{'CO_Number'}) {
			$data->{'AG_Project_ERROR'} = 'Invalid project';
			$valid = 0;
		}
	} else {
		$data->{'AG_Project_ERROR'} = 'Missing project';
		$valid = 0;
	}

	return undef unless $valid;

	# it is valid so build the sql
	my $flist = ""; # field list for insert
	my $fval = "";  # field values for insert
	my $set = "";   # set statements for update
	my $sep = '';
	
	for my $f (@cols) {
		my $val = $data->{$f};

		$flist .= "$sep$f";
		$fval .= "$sep'$val'";
		$set .= "$sep$f = '$val'";
		$sep = ',';
	}

	if ($data->{'X_Method'} eq 'Insert') {
		return "insert into agent ($flist,AG_Customer,AG_Lst_change) values ($fval,'" . 
			$data->{'CO_Number'} . "', now())";
	} else {
		return "update agent set $set, AG_Lst_change = now() where " .
			"AG_Number = " . $data->{'AG_Number'};
	}
}

sub to_list {
	my $r = shift;
	my $data = shift;

	# return to list
	$r->content_type('text/html');
	print "<html><head><script>window.location='/scripts/cust/table.php?table=agent&CO_Number=" .
		$data->{'CO_Number'};

	if ((defined($data->{'AG_Number'})) && ($data->{'AG_Number'} > 0)) {
		print "&ItemId=" . $data->{'AG_Number'};
	}

	print "'</script></head><body/></html>";

	return Apache2::Const::OK;
}

sub handler {
	my $r = shift;

	my $req = Apache2::Request->new($r, 
		POST_MAX => 10*1024,
		DISABLE_UPLOADS => 1);

	my $dbh = DialerUtils::db_connect(); 
	my $data = DialerUtils::step_one($req, $dbh,
		$req->param->{'CO_Number'}, 0);

	my $res;

	if ((defined($data->{'ErrStr'})) && (length($data->{'ErrStr'}) > 0)) {
		$data->{'ErrStr'} .= "\nAuthorization failed";
	} elsif (!defined($data->{'X_Method'})) {
		$data->{'ErrStr'} = "X_Method parameter not specified";
	} elsif ($data->{'Z_CO_Permitted'} ne 'Yes') {
		$data->{'ErrStr'} .= " Not authorized. Try to login again";
	}

	if (length($data->{'ErrStr'}) == 0) {
		# logged in so ...

		if ($data->{'X_Method'} eq 'Delete') {
			$dbh->do("delete from agent where AG_Customer = '" .
				$data->{'CO_Number'} . "' and AG_Number = '" .
				$data->{'AG_Number'} . "' limit 1");
			return to_list($r, $data);
		} elsif (($data->{'X_Method'} eq 'Insert') || ($data->{'X_Method'} eq 'Update')) {
			my $sql = make_sql($data, $dbh);
			if (defined($sql)) {
				my $sth = $dbh->prepare($sql);
				my $rc = $sth->execute();
				if (! $rc) {
					$data->{'ErrStr'} = "Failed: " . $dbh->errstr;
				} else {
					if ($data->{'X_Method'} eq 'Insert') {
						$data->{'AG_Number'} = $dbh->last_insert_id(undef,undef,undef,undef);

					}
					return to_list($r, $data);
				}
			}
		} elsif ($data->{'X_Method'} eq 'Edit') {

			my $us = $dbh->selectrow_hashref("select * from agent 
				where AG_Number = '" . $data->{'AG_Number'} . "' limit 1");

			if (! defined($us->{'AG_Name'})) {
				$data->{'ErrStr'} = "No such user";
			} else {
				# copy values
				for my $k (keys %{$us}) {
					$data->{$k} = $us->{$k};
				}

				$data->{'X_Method'} = 'Update';
			}

		} elsif ($data->{'X_Method'} eq 'New') {
			# returns a new empty agent
			$data->{'X_Method'} = 'Insert';
			$data->{'AG_Customer'} = $data->{'ContextCustomer'}{'CO_Number'};
			$data->{'AG_Name'} = "";
			$data->{'AG_Project'} = "";
			$data->{'AG_Password'} = 1000 + int(rand(9000));
			$data->{'AG_Email'} = "";
			$data->{'AG_CallBack'} = "";
			$data->{'AG_Status'} = "A";
			$data->{'AG_MustLogin'} = "Y";
		} else {
			$data->{'ErrStr'} = "Method " . $data->{'X_Method'} .
				" is not implemented";
		}
	}
	$dbh->disconnect;

	# build list of projects
	$data->{'ProjectList'} = $dbh->selectall_arrayref(
		"select PJ_Number, PJ_Description from project where
		PJ_CustNumber = '" . $data->{'CO_Number'} . "' and
		PJ_Visible = 1 and PJ_Type != 'A' and PJ_Type != 'S'",
		{ Slice => {}});

	# render the page
	$req->content_type('text/html');
	my $tt = Template->new(INCLUDE_PATH => '/dialer/www/perl')
		|| die $Template::ERROR, "\n";
	$tt->process('AgentRow.tt2', $data) || die $tt->error(), "\n";

	return Apache2::Const::OK;
}
1;
