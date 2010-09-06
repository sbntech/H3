#!/usr/bin/perl

package Payment;

# charges credit cards - to increase a reseller balance
# charges credit cards - to increase a customer balance
# maintains periodic credit card payment for a customer

use strict;
use warnings;
use DateTime;
use CreditCard;
use Net::SMTP;
use Crypt::CBC;

use Apache2::Const qw(:methods :common);

sub copyUI_to_CC {
	my $data = shift;
	my $cc = shift;

	# copy UI fields CC_* to the credit card object
	$cc->{'CustName'} = $data->{'PY_Name'}; # could be reseller name
	for my $dk (keys %$data) {
		next if (substr($dk,0,3) ne 'CC_');
		my $ck = substr($dk,3);

		if (defined($cc->{$ck})) {
			# e.g. $cc->{Type} = $data->{CC_Type}
			$cc->{$ck} = $data->{$dk};
		}
	}
}

sub copyCC_errors_toUI {
	my $data = shift;
	my $errors = shift;

	for my $k (keys %$errors) {
		$data->{"CC_$k" . '_ERROR'} = $errors->{$k};
	}
}

sub handler {
	my $r = shift;

	my $TESTING = 0;

	my $req = Apache2::Request->new($r, 
		POST_MAX => 10*1024,
		DISABLE_UPLOADS => 1);

	my $dbh = DialerUtils::db_connect(); 
	my $data = DialerUtils::step_one($req, $dbh,
		$req->param->{'CO_Number'}, 0);

	# Note: HTTP_Host is a param

	# some defaults 
	$data->{'PayType'} = 'BAD'; # CARL|CUST|RESELLER
	$data->{'PY_Name'} = 'Unknown';
	$data->{'PY_Credit'} = 0;
	$data->{'Factor'} = 1;
	$data->{'ShowCardDetails'} = 'Yes';
	$data->{'ShowPeriodicDetails'} = 'No';

	# mangling
	for my $f ('CC_Number', 'CC_CVV', 'CC_BillingZip', 'CC_BillingPhone') {
		if (defined($data->{$f})) {
			$data->{$f} =~ tr/0-9//cd; # delete all non-digits
		}
	}
	if (defined($data->{'CC_BillingState'})) {
		$data->{'CC_BillingState'} = uc($data->{'CC_BillingState'});
	}

	# authorized?
	if (defined($data->{'RS_DistribCode'})) {
		# called as ---> distributor
		$data->{'ErrStr'} = ''; # clearing the step_one error
		if (! defined($data->{'RS_Number'})) {
			$data->{'ErrStr'} = "Malformed distributor payment URL";
		} else {
			$data->{'RS_Number'} =~ tr/0-9//cd;
			my $row = $dbh->selectrow_hashref('select RS_Name, RS_Credit, RS_DistribCode, RS_DistribFactor ' .
				'from reseller where RS_Number = '. $data->{'RS_Number'});

			if ((!defined($row->{'RS_DistribCode'})) || 
				($row->{'RS_DistribCode'} ne $data->{'RS_DistribCode'})) {
					$data->{'ErrStr'} = "Distributor not authorized on this reseller.";
			}

			# initialize for distributor
			$data->{'PayType'} = "RESELLER";
			$data->{'PY_Name'} = $row->{'RS_Name'};
			$data->{'PY_Credit'} = $row->{'RS_Credit'};
			$data->{'Factor'} = $row->{'RS_DistribFactor'} ? $row->{'RS_DistribFactor'} : 1;
		}
	} else {
		if ((defined($data->{'ErrStr'})) && (length($data->{'ErrStr'}) > 0)) {
			$data->{'ErrStr'} .= "\nAuthorization failed";
		} elsif ($data->{'CO_Number'}) {
			# called for ---> customer (charge card | create PPay)
			if ($data->{'Z_CO_Permitted'} ne 'Yes') {
				$data->{'ErrStr'} .= " Not authorized.";
			} else {
				if (($data->{'ContextCustomer'}{'CO_ResNumber'} == 77) || ($data->{'ContextCustomer'}{'CO_ResNumber'} == 123)) {
					$data->{'PayType'} = "CARL";
				} else {
					$data->{'PayType'} = "CUST";
					if ($data->{'ContextCustomer'}{'CO_ResNumber'} != 1) {
						# UI should prevent this
						$data->{'ErrStr'} = 'Please contact the helpdesk for suitable payment methods';
					}
				}
				$data->{'PY_Name'} = $data->{'ContextCustomer'}{'CO_Name'};
				$data->{'PY_Credit'} = $data->{'ContextCustomer'}{'CO_Credit'};

				if ((defined($data->{'X_Method'})) && ($data->{'X_Method'} eq 'Periodic')) {
					# fetching a periodic payment
					$data->{'ShowPeriodicDetails'} = 'Yes';
					$data->{'CC_BillingCountry'} = 'US';

					$data->{'PeriodicPay'} = $dbh->selectrow_hashref("select * from periodicpay
						where PP_Customer = '" . $data->{'CO_Number'} . "'");

					if (defined($data->{'PeriodicPay'}{'PP_Customer'})) {
						# already existing periodic payment
						$data->{'ShowCardDetails'} = 'No';
						$data->{'CC_Amount'} = $data->{'PeriodicPay'}{'PP_ChargeAmount'};
					} else {
						# no existing record (so a new empty one)
						my $def = 0;
						if ((defined($data->{'ContextCustomer'}{'CO_AuthorizedAgents'})) &&
							($data->{'ContextCustomer'}{'CO_AuthorizedAgents'} > 0) &&
							(defined($data->{'ContextCustomer'}{'CO_AgentCharge'})) &&
							($data->{'ContextCustomer'}{'CO_AgentCharge'} > 0)) {
							
							# calculate a default amount for a new periodic payment
							$def = $data->{'ContextCustomer'}{'CO_AuthorizedAgents'} *
								$data->{'ContextCustomer'}{'CO_AgentCharge'};
							
						}

						$data->{'CC_Amount'} = $def;
						$data->{'PeriodicPay'} = {
									'PP_SetupDT' => "",
									'PP_LastPayDT' => "",
									'PP_Error' => "",
									'PP_Last4' => ""};
					}
				}
			}
		} elsif ($data->{'Session'}{'L_Level'} == 6) {
			$data->{'ErrStr'} = 'Failed to determine whom the payment is for';
		} elsif ($data->{'Session'}{'L_Level'} == 5) {
			# called from reseller's main page - i.e. the reseller is paying
			$data->{'PayType'} = "RESELLER";
			$data->{'PY_Name'} = $data->{'ContextReseller'}{'RS_Name'};
			$data->{'PY_Credit'} = $data->{'ContextReseller'}{'RS_Credit'};
			$data->{'Factor'} = $data->{'ContextReseller'}{'RS_DistribFactor'} ? $data->{'ContextReseller'}{'RS_DistribFactor'} : 1;
		} else {
			$data->{'ErrStr'} = "Malformed URL";
		}
	}

	if (! $data->{'ErrStr'}) {
		if (!defined($data->{'X_Method'})) {
			# drop through and show
			$data->{'CC_BillingCountry'} = 'US';
		} elsif ($data->{'X_Method'} eq 'Create') {
			$data->{'ShowCardDetails'} = 'Yes';
			$data->{'ShowPeriodicDetails'} = 'Yes';

			my $cc = CreditCard->forge($TESTING);
			copyUI_to_CC($data,$cc);

			my $errors = $cc->validate_card_details();
			if (scalar(keys %$errors) > 0) {
				copyCC_errors_toUI($data, $errors);
			} else {
				my $json = JSON::to_json($cc->TO_JSON);
				my $Last4 = substr($data->{'CC_Number'},-4);
				my $s = DialerUtils::tellSecret();

				if (defined($s)) {
					# encrypt the details
					my $cipher = Crypt::CBC->new
						( 	-key => $s, 
							-cipher => 'Blowfish',
							-header => 'none',
							-iv		=> "$Last4$Last4");

					my $ciphertext = $cipher->encrypt_hex($json);

					my $aff = $dbh->do("insert into periodicpay 
						set PP_Customer = '" . $data->{'CO_Number'} . "', 
						PP_ChargeAmount = '" . $data->{'CC_Amount'} . "', 
						PP_SetupDT = now(),
						PP_Last4 = '$Last4',
						PP_CardDetails = '$ciphertext'");

					if ($aff == 1) {
						# all is well
						$data->{'ShowCardDetails'} = 'No';
						$data->{'ShowCardDetails'} = 'No';
						$data->{'PPayStr'} = "Periodic Payment info was saved.";

						# reload the data
						$data->{'PeriodicPay'} = $dbh->selectrow_hashref("select * from periodicpay
							where PP_Customer = '" . $data->{'CO_Number'} . "'");

					} else {
						$data->{'ErrStr'} = "Failed to save the record. " . $dbh->{'mysql_error'};
					}
				} else {
					$data->{'ErrStr'} = "System failure. Contact support about blowfish init.";
				}
			}

		} elsif ($data->{'X_Method'} eq 'Delete') {
			$data->{'ShowCardDetails'} = 'Yes';
			$data->{'ShowPeriodicDetails'} = 'Yes';
			$dbh->do("delete from periodicpay where PP_Customer = '" 
						. $data->{'CO_Number'} . "'");
			$data->{'PPayStr'} = "Periodic Payment deleted permanently.";

		} elsif ($data->{'X_Method'} eq 'Update') {
			$data->{'ShowCardDetails'} = 'No';
			$data->{'ShowPeriodicDetails'} = 'Yes';

			if ($data->{'CC_Amount'} > 0) {
				my $upd = $dbh->do("update periodicpay 
						set PP_ChargeAmount = '" 
						. $data->{'CC_Amount'} . "'
						where PP_Customer = '" 
						. $data->{'CO_Number'} . "'");
				if ($upd == 1) {
					$data->{'PPayStr'} = "Periodic Payment amount changed";

					# load the data - for display
					$data->{'PeriodicPay'} = $dbh->selectrow_hashref("select * from periodicpay
						where PP_Customer = '" . $data->{'CO_Number'} . "'");
				} else {
					$data->{'ErrStr'} = "Failed to update the record. " . $dbh->{'mysql_error'};
				}
			} else {
				$data->{'CC_Amount_ERROR'} = "Must be > 0";
			}
		} elsif ($data->{'X_Method'} eq 'Send Payment') {

			my $cc = CreditCard->forge($TESTING);
			copyUI_to_CC($data,$cc);

			my $merchant = 'SBN';
			$merchant = 'CARL' if ($data->{'PayType'} eq 'CARL');
			my $API_Response = $cc->sale($data->{'CC_Amount'}, $merchant);

			if ($API_Response->{'Attribute_Errors'}) {
				copyCC_errors_toUI($data, $API_Response->{'Attribute_Errors'});
			} else {
				if (! defined($API_Response->{'Processing_Error'})) {
					my $email;
					if ($TESTING) {
						$email = "To: tech\@quickdials.com\nFrom: root\@quickdials.com\n" .
						"Subject: [TESTMODE] Successful CC Transaction\n\n";
					} else {
						$email = "To: support\@quickdials.com\nFrom: root\@quickdials.com\n" .
						"Subject: Successful CC Transaction\n\n";
					}

					# update the database
					my $mode = 'customer';
					my $id = $data->{'CO_Number'};
					my $amt = $data->{'CC_Amount'};

					if ($data->{'PayType'} eq 'CUST') {
						$email .= 'Customer Id ' . $data->{'CO_Number'} . ' increased credit by ' .
							$data->{'CC_Amount'};
					} elsif ($data->{'PayType'} eq 'CARL') {
						$email .= '<< Carl >> Customer Id ' . $data->{'CO_Number'} . ' increased credit by ' .
							$data->{'CC_Amount'};
					} else { # reseller paid
						$mode = 'reseller';
						$id = $data->{'RS_Number'};
						$amt = $data->{'CC_Amount'} * $data->{'Factor'};
						$email .= 'Reseller Id ' . $data->{'RS_Number'} . 
							" increased credit by $amt after payment of " .
							$data->{'CC_Amount'};
					}

					my ($rc, $rmsg) = DialerUtils::add_credit($dbh, 
						'Mode' 		=> $mode,
						'Amount'    => $amt,
						'Id_Number' => $id,
						'ac_user'   => 'sys_cc_pay',
						'ac_ipaddress' => $r->connection()->remote_ip()
					);

					if (! $rc) {
						$email .= "\n\naddcredit failed: $rmsg\n\n";
					}


					my $nowdt = DateTime->now();
					$nowdt->set_time_zone('America/Los_Angeles');
					$data->{'SuccessStr'} = $nowdt->ymd . ' ' . $nowdt->hms;
					$email .= "\nDate: " . $data->{'SuccessStr'} . ' Pacific' . 
						"\nName: " . $data->{'CC_NameOnCard'} .
						"\nCust/Reslr Name: " . $data->{'PY_Name'};

					for my $f (sort keys %{$API_Response->{'Result'}}) {
						$email .= "\n$f = " . $API_Response->{'Result'}{$f};
					}

					# send an email
					my $smtp = Net::SMTP->new("10.80.2.1", Timeout => 60, Debug => 0);
					if ($smtp) {
						$smtp->mail('root@quickdials.com');
						if ($TESTING) {
							$smtp->to('tech@quickdials.com');
						} else {
							$smtp->to('support@quickdials.com');
							if ($data->{'PayType'} eq 'CARL') {
								$smtp->cc('support@bullseyebroadcast.com');
							} else {
								$smtp->cc('janneke@jannekesmit.com');
							}
						}
						$smtp->data();
						$smtp->datasend($email);
						$smtp->dataend();
						$smtp->quit;
					} else {
						warn "failed to smtp: $!";
					}
				} else {
					$data->{'Processing_Error'} = $API_Response->{'Processing_Error'};

					my $nowdt = DateTime->now();
					$nowdt->set_time_zone('America/Los_Angeles');
					$data->{'FailureStr'} = $nowdt->ymd . ' ' . $nowdt->hms;
					my $email; 
					if ($TESTING) {
						$email = "To: tech\@quickdials.com\nFrom: root\@quickdials.com\n"
									. "Subject: [TESTMODE] Failed CC Transaction\n\n";
					} else {
						$email = "To: support\@quickdials.com\nFrom: root\@quickdials.com\n"
									. "Subject: Failed CC Transaction\n\n";
					}

					$email .= "\nDate: " . $data->{'FailureStr'} . ' Pacific' . 
						"\nName: " . $data->{'CC_NameOnCard'} .
						"\nCust/Reslr Name: " . $data->{'PY_Name'} . "\n\n";
						
					if (defined($API_Response->{'Result'})) {
						for my $f (sort keys %{$API_Response->{'Result'}}) {
							$email .= "\n$f = " . $API_Response->{'Result'}{$f};
						}
					}

					# send an email
					my $smtp = Net::SMTP->new("10.80.2.1", Timeout => 60, Debug => 0);
					if ($smtp) {
						$smtp->mail('root@quickdials.com');
						if ($TESTING) {
							$smtp->to('tech@quickdials.com');
						} else {
							$smtp->to('support@quickdials.com');
							if ($data->{'PayType'} eq 'CARL') {
								$smtp->cc('support@bullseyebroadcast.com');
							} else {
								$smtp->cc('janneke@jannekesmit.com');
							}
						}

						$smtp->data();
						$smtp->datasend($email);
						$smtp->dataend();
						$smtp->quit;
					} else {
						warn "failed to smtp: $!";
					}
				}
			}
		}
	}
	$dbh->disconnect;

	# render the page
	$req->content_type('text/html');
	my $tt = Template->new(INCLUDE_PATH => '/dialer/www/perl')
		|| die $Template::ERROR, "\n";
	$tt->process('Payment.tt2', $data) || die $tt->error(), "\n";

	return Apache2::Const::OK;
}
1;
