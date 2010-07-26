#!/usr/bin/perl

package Customer;

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
	my $prevCust = shift;

	my $valid = 1;
	my $custCheck = "";
	
	# not CO_Number, CO_Credit, CO_ResNumber
	my @cols = ('CO_Password', 'CO_Name', 'CO_Address', 
		'CO_Address2', 'CO_City', 'CO_Zipcode', 'CO_State',
		'CO_Tel', 'CO_Fax', 'CO_Email',	'CO_Rate', 'CO_AgentIPRate', 'CO_Status', 
		'CO_AuthorizedAgents', 'CO_AgentCharge',
		'CO_RoundBy', 'CO_Min_Duration', 'CO_Priority', 
		'CO_Timezone', 'CO_Maxlines', 'CO_Checknodial', 
		'CO_Contact', 'CO_ManagedBy', 'CO_EnableMobile', 'CO_Billingtype', 
		'CO_OnlyColdCall');

	# cleanse first
	for my $f (@cols) {
		if (defined($data->{$f})) {
			$data->{$f} =~ s/['"]//g;
			$data->{$f} =~ s/^\s*(.*)\s*$/$1/g; # trim
		}
	}

	# CO_Number
	if (DialerUtils::is_blank_str($data->{'CO_Number'})) {
		if ($data->{'X_Method'} eq 'Update') {
			$data->{'ErrStr'} = 'Customer number was missing for Update';
			return undef; # no point continuing, this is serious
		}
	} else {
		if ($data->{'X_Method'} eq 'Insert') {
			$data->{'ErrStr'} = 'Customer number cannot be provided for Insert';
			return undef; # no point continuing, this is serious
		} 
		$custCheck = 'and CO_Number != ' . $data->{'CO_Number'};
	}

	# CO_Name
	if (DialerUtils::is_blank_str($data->{'CO_Name'})) {
		$data->{'CO_Name_ERROR'} = 'Required';
		$valid = 0;
	} else {
		# check for uniqueness
		my $nameFind = $dbh->selectrow_hashref(
			"select count(*) as cnt from customer
			where CO_Name = '" . $data->{'CO_Name'} .
			"' $custCheck");

		if ($nameFind->{'cnt'} > 0) {
			$data->{'CO_Name_ERROR'} = 'Not unique';
			$valid = 0;
		}
	}

	# required strings
	$valid = required($data,'CO_Password') ? $valid : 0;
	$valid = required($data,'CO_Address') ? $valid : 0;
	$valid = required($data,'CO_Address2') ? $valid : 0;
	$valid = required($data,'CO_City') ? $valid : 0;
	$valid = required($data,'CO_Zipcode') ? $valid : 0;
	$valid = required($data,'CO_State') ? $valid : 0;
	$valid = required($data,'CO_Tel') ? $valid : 0;
	$valid = required($data,'CO_Fax') ? $valid : 0;
	$valid = required($data,'CO_Email') ? $valid : 0;
	$valid = required($data,'CO_Contact') ? $valid : 0;

	# CO_AgentCharge
	$data->{'CO_AgentCharge'} = DialerUtils::make_a_float($data->{'CO_AgentCharge'});
	if ($data->{'CO_AgentCharge'} < 0) {
		$data->{'CO_AgentCharge_ERROR'} = 'Must be >= 0';
		$valid = 0;
	}

	# CO_AuthorizedAgents
	$data->{'CO_AuthorizedAgents'} = DialerUtils::make_an_int($data->{'CO_AuthorizedAgents'});
	if ($data->{'X_Method'} eq 'Insert') {
		if ($data->{'CO_AuthorizedAgents'} != 0) {
			$data->{'CO_AuthorizedAgents'} = 0;
			$data->{'CO_AuthorizedAgents_ERROR'} = 'Must be 0. Add credit first';
			$valid = 0;
		}
	} else {
		# guaranteed to be update not insert
		if ($data->{'CO_AuthorizedAgents'} < 0) {
			$data->{'CO_AuthorizedAgents_ERROR'} = 'Must be >= 0';
			$valid = 0;
		} elsif ($data->{'CO_AuthorizedAgents'} > 0) {
			if ((defined($prevCust)) && (defined($prevCust->{'CO_AuthorizedAgents'}))
										&& ($prevCust->{'CO_AuthorizedAgents'} >= 0)) {

				my $delta = $data->{'CO_AuthorizedAgents'} - $prevCust->{'CO_AuthorizedAgents'};

				if (($delta > 0) && ($data->{'CO_AgentCharge'} > 0)) {
					# determine if customer can afford the increase...
					my $funded = int($prevCust->{'CO_Credit'} / $data->{'CO_AgentCharge'});
					$funded = 0 if ($funded < 0);

					if ($funded < $delta) {
						$data->{'CO_AuthorizedAgents_ERROR'} = 
							'Insufficient credit $' . sprintf('%0.2f', $prevCust->{'CO_Credit'}) .
								' for this increase. (Need $'
								. sprintf('%0.2f', $data->{'CO_AgentCharge'} * $delta) 
								. ')';
						$valid = 0;
					}
				}
				$data->{'X_IncreaseAgents'} = $delta;
			} else {
				$data->{'CO_AuthorizedAgents_ERROR'} = 'Cannot determine previous value';
				$valid = 0;
			}
		}
	}


	# CO_Rate
	$data->{'CO_Rate'} = DialerUtils::make_a_float($data->{'CO_Rate'});
	if ($data->{'CO_Rate'} < 0) {
		$data->{'CO_Rate_ERROR'} = 'Must be => 0';
		$valid = 0;
	} elsif (($data->{'CO_Rate'} > 0.5) && ($data->{'CO_Billingtype'} ne 'C')) {
		$data->{'CO_Rate_ERROR'} = 'Must be < 0.5';
		$valid = 0;
	}

	# CO_AgentIPRate
	$data->{'CO_AgentIPRate'} = DialerUtils::make_a_float($data->{'CO_AgentIPRate'});
	if ($data->{'CO_AgentIPRate'} < 0) {
		$data->{'CO_AgentIPRate_ERROR'} = 'Must be > 0';
		$valid = 0;
	} elsif (($data->{'CO_AgentIPRate'} > 0.5) && ($data->{'CO_Billingtype'} ne 'C')) {
		$data->{'CO_AgentIPRate_ERROR'} = 'Must be < 0.5';
		$valid = 0;
	}

	# CO_RoundBy
	$data->{'CO_RoundBy'} = DialerUtils::make_an_int($data->{'CO_RoundBy'});
	if ($data->{'CO_RoundBy'} < 0) {
		$data->{'CO_RoundBy_ERROR'} = 'Must be > 0';
		$valid = 0;
	}

	# CO_Min_Duration
	$data->{'CO_Min_Duration'} = DialerUtils::make_an_int($data->{'CO_Min_Duration'});
	if ($data->{'CO_Min_Duration'} < 0) {
		$data->{'CO_Min_Duration_ERROR'} = 'Must be >= 0';
		$valid = 0;
	}

	# CO_Priority
	$data->{'CO_Priority'} = DialerUtils::make_an_int($data->{'CO_Priority'});
	if ($data->{'CO_Priority'} < 0) {
		$data->{'CO_Priority_ERROR'} = 'Must be >= 0';
		$valid = 0;
	} elsif ($data->{'CO_Priority'} > 10) {
		$data->{'CO_Priority_ERROR'} = 'Must be < 10';
		$valid = 0;
	} 

	# CO_Maxlines
	$data->{'CO_Maxlines'} = DialerUtils::make_an_int($data->{'CO_Maxlines'});
	if ($data->{'CO_Maxlines'} <= 0) {
		$data->{'CO_Maxlines_ERROR'} = 'Must be > 0';
		$valid = 0;
	}


	# CO_Status
	if (! DialerUtils::valid_values_str($data->{'CO_Status'},'A', 'B')) {
		$data->{'CO_Status_ERROR'} = 'Not a valid value';
		$valid = 0;
	}

	# CO_Timezone
	if (! DialerUtils::valid_values_str($data->{'CO_Timezone'},
			'0', '-1', '-2', '-3')) {
		$data->{'CO_Timezone_ERROR'} = 'Not a valid value';
		$valid = 0;
	}

	# CO_Checknodial
	if (! DialerUtils::valid_values_str($data->{'CO_Checknodial'},'T', 'F')) {
		$data->{'CO_Checknodial_ERROR'} = 'Not a valid value';
		$valid = 0;
	}

	# CO_EnableMobile
	if (! DialerUtils::valid_values_str($data->{'CO_EnableMobile'},'T', 'F')) {
		$data->{'CO_EnableMobile_ERROR'} = 'Not a valid value';
		$valid = 0;
	}

	# CO_OnlyColdCall
	if (! DialerUtils::valid_values_str($data->{'CO_OnlyColdCall'}, 'Y', 'N')) {
		$data->{'CO_OnlyColdCall_ERROR'} = 'Not a valid value';
		$valid = 0;
	}

	# CO_Billingtype
	if (! DialerUtils::valid_values_str($data->{'CO_Billingtype'}, 'T', 'F', 'A', 'C')) {
		$data->{'CO_Billingtype_ERROR'} = 'Not a valid value';
		$valid = 0;
	}

	if (! $valid) {
		# which fields?
		my $ferrs = ''; 
		for my $k (keys %$data) {
			if ($k =~ /^CO_(.*)_ERROR$/) {
				$ferrs .= "$1 ";
			}
		}

		$data->{'Processing_Error'} = "Field error(s) occurred ($ferrs)";

		return undef;
	}

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
		return "insert into customer ($flist,CO_Credit,CO_ResNumber)
			values ($fval,0, " . $data->{'ContextReseller'}{'RS_Number'} . ")";
	} else {
		return "update customer set $set where " .
			"CO_Number = " . $data->{'CO_Number'};
	}
}

sub to_list {
	my $r = shift;
	# return to list
	$r->content_type('text/html');
	print "<html><head><script>window.location='/pg/CustomerList'</script></head><body/></html>";
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

	if ((defined($data->{'ErrStr'})) && (length($data->{'ErrStr'}) > 0)) {
		$data->{'ErrStr'} .= "\nAuthorization failed";
	} elsif ($data->{'Session'}{'L_Level'} < 5) {
		$data->{'ErrStr'} = "Need supervisor rights for this.";
	} else { # logged in so ...
		if (! defined($data->{'X_Method'})) {
			$data->{'ErrStr'} = "X_Method must be provided";
		} elsif ($data->{'X_Method'} eq 'New') {
			# returns a new empty customer
			$data->{'X_Method'} = 'Insert';

			$data->{'CO_ResNumber'} = $data->{'ContextReseller'}{'RS_Number'};
			$data->{'CO_Number'} = '';
			$data->{'CO_Password'} = '';
			$data->{'CO_Name'} = '';
			$data->{'CO_Address'} = '';
			$data->{'CO_Address2'} = '';
			$data->{'CO_City'} = '';
			$data->{'CO_Zipcode'} = '';
			$data->{'CO_State'} = '';
			$data->{'CO_Tel'} = '';
			$data->{'CO_Fax'} = '';
			$data->{'CO_Email'} = '';
			$data->{'CO_Credit'} = 0;
			$data->{'X_AddCredit'} = 0;
			$data->{'CO_Rate'} = 0.05;
			$data->{'CO_AgentIPRate'} = 0.05;
			$data->{'CO_Status'} = 'A';
			$data->{'CO_RoundBy'} = 6;
			$data->{'CO_Min_Duration'} = 6;
			$data->{'CO_Priority'} = 5;
			$data->{'CO_Timezone'} = 0;
			$data->{'CO_Maxlines'} = 500;
			$data->{'CO_Checknodial'} = 'F';
			$data->{'CO_Contact'} = '';
			$data->{'CO_ManagedBy'} = '';
			$data->{'CO_EnableMobile'} = 'F';
			$data->{'CO_Billingtype'} = 'T';
			$data->{'CO_AgentCharge'} = 0;
			$data->{'CO_AuthorizedAgents'} = 0;
			$data->{'CO_OnlyColdCall'} = 'Y';
		} elsif ($data->{'X_Method'} eq 'Edit') {
			$data->{'X_AddCredit'} = 0;
			$data->{'X_Method'} = 'Update';
			for my $k (keys %{$data->{'ContextCustomer'}}) {
				$data->{$k} = $data->{'ContextCustomer'}{$k};
			}
		} elsif (($data->{'X_Method'} eq 'Update') || ($data->{'X_Method'} eq 'Insert')) {
			$data->{'CO_ResNumber'} = $data->{'ContextReseller'}{'RS_Number'};

			my $sql = make_sql($data, $dbh, $data->{'ContextCustomer'});

			if (defined($sql)) {
				my $rc = $dbh->do($sql);
				if (! $rc) {
					$data->{'ErrStr'} = "Failed: " . $dbh->errstr;
				} else {
					if ($data->{'X_Method'} eq 'Insert') {
						$data->{'CO_Number'} = $dbh->last_insert_id(undef,undef,undef,undef);
					}
					if ((defined($data->{'X_IncreaseAgents'})) &&
							($data->{'CO_Number'} > 0) &&
							($data->{'X_IncreaseAgents'}  > 0)) {

						# an increase in CO_AuthorizedAgents requires it gets billed
						my $custCharge = $data->{'X_IncreaseAgents'} * $data->{'CO_AgentCharge'};

						# charge the customer
						my $AgErr = '';
						my $resCharge = 0;
						$rc = $dbh->do("update customer set CO_Credit = CO_Credit - $custCharge
							where CO_Number = " . $data->{'CO_Number'} . " limit 1");
						if ($rc == 1) {
							# determine the reseller's charge
							if ($data->{'CO_ResNumber'} > 1) {

								$resCharge = (($custCharge * $data->{'ContextReseller'}{'RS_AgentChargePerc'}) / 100)
									+ ($data->{'X_IncreaseAgents'} * $data->{'ContextReseller'}{'RS_AgentCharge'});

								# bill the reseller (they can go negative)
								$rc = $dbh->do("update reseller set RS_Credit = RS_Credit - $resCharge
									where RS_Number = " . $data->{'CO_ResNumber'} . " limit 1");
								unless ($rc == 1) {
									$data->{'ErrStr'} = "Charging for agents failed: " . $dbh->errstr;
									$AgErr = "db update (resCharge=$resCharge) failed: " . $dbh->errstr;
									$resCharge = 0;
								}
							}
						} else {
							$data->{'ErrStr'} = "Charging for agents failed: " . $dbh->errstr;
							$AgErr = "db update (custCharge=$custCharge) failed: " . $dbh->errstr;
							$custCharge = 0;
						}

						$rc = $dbh->do("insert into agentcharge
							(AC_Customer, AC_DateTime, AC_AgentsBefore, AC_AgentsAfter,
							 AC_CustCharge, AC_ResCharge, AC_Error) values 
							('" . $data->{'CO_Number'} . "', now(), '" .
							$data->{'ContextCustomer'}{'CO_AuthorizedAgents'} . "', '" . 
							$data->{'CO_AuthorizedAgents'} . 
							"', '$custCharge', '$resCharge', '$AgErr')"); 

						unless ($rc == 1) {
							$data->{'ErrStr'} = "agentcharge table insert failed: " 
								. $dbh->{'mysql_error'};
						}
					}

					if ((defined($data->{'X_AddCredit'})) &&
							($data->{'CO_Number'} > 0) &&
							($data->{'X_AddCredit'} != 0)) {

						my ($rc, $rmsg) = DialerUtils::add_credit($dbh, 
							'Mode' 		=> 'customer',
							'Amount'    => $data->{'X_AddCredit'},
							'Id_Number' => $data->{'CO_Number'},
							'ac_user'   => $data->{'Session'}{'L_Name'},
							'ac_ipaddress' => $r->connection()->remote_ip()
						);
						if (! $rc) {
							$data->{'ErrStr'} .= "Adding credit failed: $rmsg";
						}
					}
				}

				return to_list($r) unless ((defined($data->{'ErrStr'})) &&
											(length($data->{'ErrStr'}) > 5));
			}

			# retrieve read-only fields
			my $ronly = $dbh->selectrow_hashref("select CO_Credit
				from customer where CO_Number = '" . $data->{'CO_Number'} . 
				"' and CO_ResNumber = " . $data->{'ContextReseller'}{'RS_Number'});
			for my $k (keys %$ronly) {
				$data->{$k} = $ronly->{$k};
			}
		} else {
			$data->{'ErrStr'} = "X_Method=" . $data->{'X_Method'} . " not implemented";
		}
	}
	$dbh->disconnect;

	# render the page
	$req->content_type('text/html');
	my $tt = Template->new(INCLUDE_PATH => '/dialer/www/perl')
		|| die $Template::ERROR, "\n";
	$tt->process('Customer.tt2', $data) || die $tt->error(), "\n";

	return Apache2::Const::OK;
}
1;
