#!/usr/bin/perl

package Reseller;

use strict;
use warnings;

use Apache2::Const qw(:methods :common);

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
	my $nameCheck = "";
	
	# not RS_Number, RS_Credit
	my @cols = ('RS_Password', 'RS_Name', 'RS_Address', 
		'RS_Address2', 'RS_City', 'RS_Zipcode', 'RS_State',
		'RS_Tel', 'RS_Fax', 'RS_Email',	'RS_Rate', 'RS_AgentIPRate', 'RS_Status', 
		'RS_AgentCharge', 'RS_AgentChargePerc',
		'RS_RoundBy', 'RS_Min_Duration', 'RS_Priority', 
		'RS_Timezone', 'RS_Maxlines',  'RS_Contact',  
		'RS_DistribCode', 'RS_DistribFactor', 'RS_OnlyColdCall', 'RS_DNC_Flag');

	# cleanse first
	for my $f (@cols) {
		if (defined($data->{$f})) {
			$data->{$f} =~ s/['"]//g;
			$data->{$f} =~ s/^\s*(.*)\s*$/$1/g; # trim
		}
	}

	# RS_Number
	if (DialerUtils::is_blank_str($data->{'RS_Number'})) {
		if ($data->{'X_Method'} eq 'Update') {
			$data->{'ErrStr'} = 'Reseller number was missing for Update';
			return undef; # no point continuing, this is serious
		}
	} else {
		if ($data->{'X_Method'} eq 'Insert') {
			$data->{'ErrStr'} = 'Reseller number cannot be provided for Insert';
			return undef; # no point continuing, this is serious
		}
		$nameCheck = 'and RS_Number != ' . $data->{'RS_Number'};
	}

	# RS_Name
	if (DialerUtils::is_blank_str($data->{'RS_Name'})) {
		$data->{'RS_Name_ERROR'} = 'Required';
		$valid = 0;
	} else {
		# check for uniqueness
		my $nameFind = $dbh->selectrow_hashref(
			"select count(*) as cnt from reseller
			where RS_Name = '" . $data->{'RS_Name'} .
			"' $nameCheck");

		if ($nameFind->{'cnt'} > 0) {
			$data->{'RS_Name_ERROR'} = 'Not unique';
			$valid = 0;
		}
	}

	# required strings
	$valid = required($data,'RS_Password') ? $valid : 0;
	$valid = required($data,'RS_Address') ? $valid : 0;
	$valid = required($data,'RS_Address2') ? $valid : 0;
	$valid = required($data,'RS_City') ? $valid : 0;
	$valid = required($data,'RS_Zipcode') ? $valid : 0;
	$valid = required($data,'RS_State') ? $valid : 0;
	$valid = required($data,'RS_Tel') ? $valid : 0;
	$valid = required($data,'RS_Fax') ? $valid : 0;
	$valid = required($data,'RS_Email') ? $valid : 0;
	$valid = required($data,'RS_Contact') ? $valid : 0;

	# RS_DistribCode
	if (! DialerUtils::is_blank_str($data->{'RS_DistribCode'})) {
		if (length($data->{'RS_DistribCode'}) != 32) {
			$data->{'RS_DistribCode_ERROR'} = 'Must be 32 chars';
			$valid = 0;
		}
		# RS_DistribFactor
		$data->{'RS_DistribFactor'} = DialerUtils::make_a_float($data->{'RS_DistribFactor'});
		if ($data->{'RS_DistribFactor'} <= 1) {
			$data->{'RS_DistribFactor_ERROR'} = 'Must be > 1';
			$valid = 0;
		} elsif ($data->{'RS_DistribFactor'} > 10) {
			$data->{'RS_DistribFactor_ERROR'} = 'Must be < 10';
			$valid = 0;
		}
	}

	# RS_AgentCharge
	$data->{'RS_AgentCharge'} = DialerUtils::make_a_float($data->{'RS_AgentCharge'});
	if ($data->{'RS_AgentCharge'} < 0) {
		$data->{'RS_AgentCharge_ERROR'} = 'Must be >= 0';
		$valid = 0;
	}

	# RS_AgentChargePerc
	$data->{'RS_AgentChargePerc'} = DialerUtils::make_a_float($data->{'RS_AgentChargePerc'});
	if ($data->{'RS_AgentChargePerc'} < 0) {
		$data->{'RS_AgentChargePerc_ERROR'} = 'Must be >= 0';
		$valid = 0;
	} elsif ($data->{'RS_AgentChargePerc'} > 100.0) {
		$data->{'RS_AgentChargePerc_ERROR'} = 'Must be <= 100';
		$valid = 0;
	}

	# RS_Rate
	$data->{'RS_Rate'} = DialerUtils::make_a_float($data->{'RS_Rate'});
	if ($data->{'RS_Rate'} <= 0) {
		$data->{'RS_Rate_ERROR'} = 'Must be > 0';
		$valid = 0;
	} elsif ($data->{'RS_Rate'} > 0.5) {
		$data->{'RS_Rate_ERROR'} = 'Must be < 0.5';
		$valid = 0;
	}

	# RS_AgentIPRate
	$data->{'RS_AgentIPRate'} = DialerUtils::make_a_float($data->{'RS_AgentIPRate'});
	if ($data->{'RS_AgentIPRate'} < 0) {
		$data->{'RS_AgentIPRate_ERROR'} = 'Must be >= 0';
		$valid = 0;
	} elsif ($data->{'RS_AgentIPRate'} > 0.5) {
		$data->{'RS_AgentIPRate_ERROR'} = 'Must be < 0.5';
		$valid = 0;
	}

	# RS_RoundBy
	$data->{'RS_RoundBy'} = DialerUtils::make_an_int($data->{'RS_RoundBy'});
	if ($data->{'RS_RoundBy'} < 0) {
		$data->{'RS_RoundBy_ERROR'} = 'Must be >= 0';
		$valid = 0;
	}

	# RS_Min_Duration
	$data->{'RS_Min_Duration'} = DialerUtils::make_an_int($data->{'RS_Min_Duration'});
	if ($data->{'RS_Min_Duration'} < 0) {
		$data->{'RS_Min_Duration_ERROR'} = 'Must be >= 0';
		$valid = 0;
	}

	# RS_Priority
	$data->{'RS_Priority'} = DialerUtils::make_an_int($data->{'RS_Priority'});
	if ($data->{'RS_Priority'} < 0) {
		$data->{'RS_Priority_ERROR'} = 'Must be >= 0';
		$valid = 0;
	} elsif ($data->{'RS_Priority'} > 10) {
		$data->{'RS_Priority_ERROR'} = 'Must be < 10';
		$valid = 0;
	} 

	# RS_Maxlines
	$data->{'RS_Maxlines'} = DialerUtils::make_an_int($data->{'RS_Maxlines'});
	if ($data->{'RS_Maxlines'} <= 0) {
		$data->{'RS_Maxlines_ERROR'} = 'Must be > 0';
		$valid = 0;
	}

	# RS_Status
	if (! DialerUtils::valid_values_str($data->{'RS_Status'},'A', 'B')) {
		$data->{'RS_Status_ERROR'} = 'Not a valid value';
		$valid = 0;
	}

	# RS_OnlyColdCall
	if (! DialerUtils::valid_values_str($data->{'RS_OnlyColdCall'}, 'Y', 'N', 'M')) {
		$data->{'RS_OnlyColdCall_ERROR'} = 'Not a valid value';
		$valid = 0;
	}

	# RS_Timezone
	if (! DialerUtils::valid_values_str($data->{'RS_Timezone'},
			'0', '-1', '-2', '-3')) {
		$data->{'RS_Timezone_ERROR'} = 'Not a valid value';
		$valid = 0;
	}

	# RS_DNC_Flag
	if (! DialerUtils::valid_values_str($data->{'RS_DNC_Flag'},
			'Y', 'N')) {
		$data->{'RS_DNC_Flag_ERROR'} = 'Not a valid value';
		$valid = 0;
	}

	return undef unless $valid;

	# it is valid so build the sql
	my $flist = ""; # field list for insert
	my $fval = "";  # field values for insert
	my $set = "";   # set statements for update

	for my $f (@cols) {
		my $val = $data->{$f};

		if (length($flist) == 0) {
			$flist .= $f;
			$fval .= qq('$val');
			$set .= qq($f = '$val');
		} else {
			$flist .= ",$f";
			$fval .= qq(,'$val');
			$set .= qq(,$f = '$val');
		}
	}

	if ($data->{'X_Method'} eq 'Insert') {
		return "insert into reseller ($flist,RS_Credit) values ($fval,0)";
	} else {
		return "update reseller set $set where " .
			"RS_Number = " . $data->{'RS_Number'};
	}
}

sub to_list {
	my $r = shift;
	# return to list
	$r->content_type('text/html');
	print "<html><head><script>window.location='/pg/ResellerList'</script></head><body/></html>";
	return Apache2::Const::OK;
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
		# logged in so ...
		if ($r->method_number == Apache2::Const::M_POST) {
			my $sql = make_sql($data, $dbh);
			if (defined($sql)) {
				my $rc = $dbh->do($sql);
				if (! $rc) {
					$data->{'ErrStr'} = "Failed: " . $dbh->errstr;
				} else {
					if ($data->{'X_Method'} eq 'Insert') {
						$data->{'RS_Number'} = $dbh->last_insert_id(undef,undef,undef,undef);
					}
					if ((defined($data->{'X_AddCredit'})) &&
							($data->{'RS_Number'} > 0) &&
							($data->{'X_AddCredit'} != 0)) {

						my ($rc, $rmsg) = DialerUtils::add_credit($dbh, 
							'Mode' 		=> 'reseller',
							'Amount'    => $data->{'X_AddCredit'},
							'Id_Number' => $data->{'RS_Number'},
							'ac_user'   => $data->{'Session'}{'L_Name'},
							'ac_ipaddress' => $r->connection()->remote_ip()
						);

						if (! $rc) {
							$data->{'ErrStr'} = "Adding credit failed: $rmsg";
						} else {
							return to_list($r);
						}
					} else {
						return to_list($r);
					}
				}
			}

			# retrieve read-only fields
			my $ronly = $dbh->selectrow_hashref(
				"select RS_Credit from reseller where RS_Number = '" . $data->{'RS_Number'} . "'");
			for my $k (keys %$ronly) {
				$data->{$k} = $ronly->{$k};
			}
		} else {
			# get
			if ((defined($data->{'RS_Number'})) && 
					($data->{'RS_Number'} =~ /\d*/)) {
				# attempt to retrieve from database
				my $crow = $dbh->selectrow_hashref(
					"select * from reseller where RS_Number = '" . $data->{'RS_Number'} . "'");

				for my $k (keys %$crow) {
					$data->{$k} = $crow->{$k};
				}
				$data->{'X_AddCredit'} = 0;
				$data->{'X_Method'} = 'Update';
			} else {
				# returns a new empty reseller
				$data->{'X_Method'} = 'Insert';

				$data->{'RS_Number'} = '';
				$data->{'RS_Password'} = '';
				$data->{'RS_Name'} = '';
				$data->{'RS_Address'} = '';
				$data->{'RS_Address2'} = '';
				$data->{'RS_City'} = '';
				$data->{'RS_Zipcode'} = '';
				$data->{'RS_State'} = '';
				$data->{'RS_Tel'} = '';
				$data->{'RS_Fax'} = '';
				$data->{'RS_Email'} = '';
				$data->{'RS_Credit'} = 0;
				$data->{'X_AddCredit'} = 0;
				$data->{'RS_Rate'} = 0.05;
				$data->{'RS_AgentIPRate'} = 0.05;
				$data->{'RS_Status'} = 'A';
				$data->{'RS_RoundBy'} = 6;
				$data->{'RS_Min_Duration'} = 6;
				$data->{'RS_Priority'} = 5;
				$data->{'RS_Timezone'} = 0;
				$data->{'RS_Maxlines'} = 3500;
				$data->{'RS_Contact'} = '';
				$data->{'RS_DistribCode'} = '';
				$data->{'RS_DistribFactor'} = '';
			}
		}
	}
	$dbh->disconnect;

	# render the page
	$req->content_type('text/html');
	my $tt = Template->new(INCLUDE_PATH => '/dialer/www/perl')
		|| die $Template::ERROR, "\n";
	$tt->process('Reseller.tt2', $data) || die $tt->error(), "\n";

	return Apache2::Const::OK;
}
1;
