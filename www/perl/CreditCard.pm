#!/usr/bin/perl

package CreditCard;

use warnings;
use strict;
use LWP;
use HTTP::Request::Common qw( POST );

# Charges credit cards

sub authorize_net {
 	my $self = shift;
	my $amount = shift;
	my $login = shift;
	my $trankey = shift;
	my $descrip = shift;

	my %API_Response; 
	# submit info to the gateway and 
	# sets API_Response{'Processing_Error'} if any failure occurs
	
	my $ccname = $self->{'NameOnCard'};
	$ccname =~ /(.*) (.*) *$/;
	my ($firstname, $lastname) = ($1, $2);
 
 	my $request_values = {
		x_test_request		=> 'FALSE', 
		x_login				=> $login, 
		x_tran_key			=> $trankey,
		x_version			=> '3.1', 
		x_delim_char		=> '|', 
		x_delim_data		=> 'TRUE', 
		x_method			=> 'CC', 
		x_type				=> 'AUTH_CAPTURE', 
		x_card_num			=> $self->{'Number'},
		x_card_code			=> $self->{'CVV'},
		x_exp_date			=> $self->{'ExpiresMonth'} . $self->{'ExpiresYear'}, 
		x_description		=> $descrip, 
		x_amount			=> $amount, 
		x_first_name		=> $firstname, 
		x_last_name			=> $lastname, 
		x_email				=> $self->{'BillingEmail'},
		x_phone				=> $self->{'BillingPhone'},
		x_address			=> $self->{'BillingAddress'}, 
		x_zip				=> $self->{'BillingZip'}, 
		x_cust_id			=> $self->{'CustName'}, 
		x_ship_to_company	=> $self->{'CustName'}, 
		x_ship_to_first_name => $firstname, 
		x_ship_to_last_name	=> $lastname, 
 	};

	if ($self->{'TESTING'} == 1) {
		# testing mode is used
		$request_values->{'x_test_request'} = 'TRUE';
	}
 
 	my $useragent = LWP::UserAgent->new(protocols_allowed => ["https"]);
	my $request	= POST("https://secure.authorize.net/gateway/transact.dll", $request_values);
	# can print  $request->as_string()  for debug purposes if needed
 	my $response = $useragent->request($request);
 
 	if (! $response->is_success ) {
		$API_Response{'Processing_Error'} = 'Unable to communicate with the authorizing site.  Try again.';
 	}

	my @fnames;
	$fnames[1 ] = 'Response Code';
	$fnames[2 ] = 'Response Subcode';
	$fnames[3 ] = 'Response Reason Code';
	$fnames[4 ] = 'Response Reason Text';
	$fnames[5 ] = 'Authorization Code';
	$fnames[6 ] = 'AVS Response';
	$fnames[7 ] = 'Transaction ID';
	$fnames[8 ] = 'Invoice Number';
	$fnames[9 ] = 'Description';
	$fnames[10] = 'Amount';
	$fnames[11] = 'Method';
	$fnames[12] = 'Transaction Type';
	$fnames[13] = 'Customer ID';
	$fnames[14] = 'First Name';
	$fnames[15] = 'Last Name';
	$fnames[16] = 'Company';
	$fnames[17] = 'Address';
	$fnames[18] = 'City';
	$fnames[19] = 'State';
	$fnames[20] = 'ZIP Code';
	$fnames[21] = 'Country';
	$fnames[22] = 'Phone';
	$fnames[23] = 'Fax';
	$fnames[24] = 'Email Address';
	$fnames[25] = 'Ship To First Name';
	$fnames[26] = 'Ship To Last Name';
	$fnames[27] = 'Ship To Company';
	$fnames[28] = 'Ship To Address';
	$fnames[29] = 'Ship To City';
	$fnames[30] = 'Ship To State';
	$fnames[31] = 'Ship To ZIP Code';
	$fnames[32] = 'Ship To Country';
	$fnames[33] = 'Tax';
	$fnames[34] = 'Duty';
	$fnames[35] = 'Freight';
	$fnames[36] = 'Tax Exempt';
	$fnames[37] = 'Purchase Order Number';
	$fnames[38] = 'MD5 Hash';
	$fnames[39] = 'Card Code Response';
	$fnames[40] = 'Cardholder Authentication Verification Response';

	my @fieldsvalues = split( /\|/, $response->content );
	my $fcnt = 1;
	for my $v (@fieldsvalues) {
		$API_Response{'Result'}{$fnames[$fcnt]} = $v;
		$fcnt++;
	}

	if ($API_Response{'Result'}{'Response Code'} == 3) {
		$API_Response{'Processing_Error'} = 'Error: ' . $API_Response{'Result'}{'Response Reason Text'};
	} elsif ($API_Response{'Result'}{'Response Code'} == 2) {
		$API_Response{'Processing_Error'} = 'Declined, use another card';
	}

	return \%API_Response;
}

sub innovativegateway_com {
	my $self = shift;
	my $amount = shift;
	my $username = shift;
	my $pw = shift;

	my %API_Response; 
	# submit info to the gateway and 
	# sets API_Response{'Processing_Error'} if any failure occurs
	
	my $request_values = {
		target_app		=> 'WebCharge_v5.06',
		response_mode	=> 'simple',
		response_fmt	=> 'delimited',
		upg_auth		=> 'zxcvlkjh',
		cardtype		=> $self->{'Type'},
		delimited_fmt_field_delimiter	=> '=',
		delimited_fmt_include_fields	=> 'true',
		delimited_fmt_value_delimiter	=> '|',
		username		=> $username, 
		pw				=> $pw,
		trantype		=> 'sale',
		ccnumber		=> $self->{'Number'},
		month			=> $self->{'ExpiresMonth'},
		year			=> $self->{'ExpiresYear'},
		fulltotal		=> $amount,
		ccname			=> $self->{'NameOnCard'},
		baddress		=> $self->{'BillingAddress'},
		baddress1		=> $self->{'BillingAddress1'},
		bcity			=> $self->{'BillingCity'},
		bstate			=> $self->{'BillingState'},
		bzip			=> $self->{'BillingZip'},
		bcountry		=> $self->{'BillingCountry'},
		bphone			=> $self->{'BillingPhone'},
		bemail			=> $self->{'BillingEmail'},
		ccidentifier1	=> $self->{'CVV'},
		CO_Number		=> $self->{'CO_Number'},

		# control fields
		ReceiptEmail	=> 'no'
	};

	if ($self->{'TESTING'} == 1) {
		# testing mode is used
		$request_values->{'test_override_errors'} = 'true';
		$request_values->{'username'} = 'gatewaytest';
		$request_values->{'pw'} = 'GateTest2002';
	}

	my $useragent = LWP::UserAgent->new(protocols_allowed => ["https"]);
	my $request	= POST("https://transaction.innovativegateway.com/servlet/com.gateway.aai.Aai", $request_values);
	my $response = $useragent->request($request);

	if (! $response->is_success ) {
		$API_Response{'Processing_Error'} = 'Unable to communicate with the authorizing gateway.  Try again.';
	}

	my @fieldsvalues = split( /\|/, $response->content );
	for (@fieldsvalues) {
		my ($f,$v) = split(/=/);
		$API_Response{'Result'}{lc($f)} = $v unless lc($f) eq 'ccnumber';
	}

	# Important response fields: anatransid,messageid,error,approval,avs
	if (defined($API_Response{'Result'}{'error'})) {
		$API_Response{'Result'}{'error'} =~ s/<[^>]*>//g;
		$API_Response{'Processing_Error'} = 'Error: ' . $API_Response{'Result'}{'error'};
	} elsif (! defined($API_Response{'Result'}{'approval'})) {
		$API_Response{'Processing_Error'} = 'Error: no approval code returned';
	}

	return \%API_Response;
}


# ===== Methods =====

sub forge {
	my $class = shift;
	my $testing = shift;

	my $self = {
		'Type' => 'amex',
		'Number' => '',
		'ExpiresMonth' => '01',
		'ExpiresYear' => '2014', 
		'NameOnCard' => '',
		'BillingAddress' => '',
		'BillingAddress1' => '',
		'BillingCity' => '', 
		'BillingState' => '', 
		'BillingZip' => '',
		'BillingCountry' => 'US',
		'BillingPhone' => '',
		'BillingEmail' => '',
		'CVV' => '',
		'CustName' => '',
		'TESTING' => $testing};

	bless $self;
	return $self;
}

sub sale {
	my $self = shift;
	my $amount = shift;
	my $merchant = shift; 

	my $Lower_Limit = 20;
	my $Upper_Limit = 15000;

	# validate the amount
	my $estr;
	if ($amount !~ /^\d{2,5}(\.\d\d)?$/) {
		$estr = "Amount does not look like a currency amount";
	} elsif ($amount < $Lower_Limit) {
		$estr = "Amount too small, must be >= \$$Lower_Limit";
	} elsif ($amount > $Upper_Limit) {
		$estr = "Amount too large, must <= \$$Upper_Limit";
	}
	if ($estr) {
		return {
			'Processing_Error' => $estr,
			'Attribute_Errors' => { 'Amount' => $estr },
			'Result' => undef };
	}

	# validate other details
	my $errors = $self->validate_card_details();
	if (scalar(keys %$errors) > 0) {
		return {
			'Processing_Error' => "Attribute validation errors occurred",
			'Attribute_Errors' => $errors,
			'Result' => undef };
	}

	if ($merchant eq 'CARL') {
		# bullseye007/Logicd007  Payment Gateway ID is: 679912
		return $self->authorize_net($amount, '4VC9bRnDh3G', '3s5M6P7FuW7Ef6jz', 'Bullseye Broadcasting');
	} else {
		return $self->innovativegateway_com($amount, 'SBNDIALS77126', 'NR2Qaj$7nVC');
	}
}

sub TO_JSON {
	my $self = shift;

	my $j;
	for my $f ('Number', 'Type', 'ExpiresMonth', 'ExpiresYear',
				'CVV', 'NameOnCard', 'BillingAddress', 'BillingAddress1', 'BillingZip',
				'BillingCity', 'BillingState', 'BillingPhone', 'BillingEmail',
				'BillingCountry') {

		$j->{$f} = $self->{$f};
	}

	return $j;
}

sub validate_card_details {
	my $self = shift;

	my $errors; # hash ref

	# --- required fields ---
	my @required = ('Number', 'CVV',
		'NameOnCard', 'BillingAddress', 'BillingZip', 'BillingCity', 'BillingState', 'BillingPhone', 
		'BillingEmail');
	for my $rf (@required) {
		if (! $self->{$rf}) {
			$errors->{$rf} = 'required field is missing';
		}
	}
	return $errors if (scalar(keys %$errors) > 0);

	# --- Number ---
	my $nlen = length($self->{'Number'});

	if ($nlen < 14) {
		$errors->{'Number'} = 'Card number is too short';
		return $errors;
	} elsif ($nlen > 16) {
		$errors->{'Number'} = 'Card number is too long';
		return $errors;
	}

	# --- Type ---
	$self->{'Type'} = 'amex' unless defined($self->{'Type'});

	if ($self->{'Type'} eq 'amex') {
		if ((substr($self->{'Number'},0,2) ne '34') &&
				(substr($self->{'Number'},0,2) ne '37')) {
			$errors->{'Type'} = 'Credit Card number is invalid amex number';
			return $errors;
		}
		if (length($self->{'Number'}) != 15) {
			$errors->{'Type'} = 'Credit Card number is not an amex number';
			return $errors;
		}
	} elsif ($self->{'Type'} eq 'discover') {
		if ((substr($self->{'Number'},0,2) ne '65') &&
				(substr($self->{'Number'},0,4) ne '6011')) {
			$errors->{'Type'} = 'Credit Card number is invalid discover number';
			return $errors;
		}
		if (length($self->{'Number'}) != 16) {
			$errors->{'Type'} = 'Credit Card number is not an discover number';
			return $errors;
		}
	} elsif ($self->{'Type'} eq 'visa') {
		if (substr($self->{'Number'},0,1) ne '4') {
			$errors->{'Type'} = 'Credit Card number is invalid visa number';
			return $errors;
		}
		if (length($self->{'Number'}) != 16) {
			$errors->{'Type'} = 'Credit Card number is not an visa number';
			return $errors;
		}
	} elsif ($self->{'Type'} eq 'mc') {
		if (substr($self->{'Number'},0,1) ne '5') { # not perfect
			$errors->{'Type'} = 'Credit Card number is invalid MasterCard number';
			return $errors;
		}
		if (length($self->{'Number'}) != 16) {
			$errors->{'Type'} = 'Credit Card number is not an MasterCard number';
			return $errors;
		}
	} elsif ($self->{'Type'} eq 'diners') {
		if (substr($self->{'Number'},0,2) ne '55') {
			$errors->{'Type'} = 'Credit Card number is invalid diners number';
			return $errors;
		}
		if (length($self->{'Number'}) != 16) {
			$errors->{'Type'} = 'Credit Card number is not an Diners number';
			return $errors;
		}
	} elsif ($self->{'Type'} eq 'jcb') {
		if ((substr($self->{'Number'},0,2) ne '35') &&
				(substr($self->{'Number'},0,4) ne '1800') &&
				(substr($self->{'Number'},0,4) ne '2131')) {
			$errors->{'Type'} = 'Credit Card number is invalid JCB number';
			return $errors;
		}
		if ((length($self->{'Number'}) != 16) && (length($self->{'Number'}) != 15)) {
			$errors->{'Type'} = 'Credit Card number is not an JCB number';
			return $errors;
		}
	}

	# --- CVV ---
	if ($self->{'CVV'} !~ /\d{3,4}/) {
		$errors->{'CVV'} = 'Invalid, 3 or 4 digits only';
		return $errors;
	}

	# --- BillingZip ---
	if ($self->{'BillingZip'} !~ /\d{5}/) {
		$errors->{'BillingZip'} = 'Zip Code is invalid, not 5 digits';
		return $errors;
	}

	# --- BillingState ---
	if ($self->{'BillingCountry'} eq 'US') {
		if (! grep {$self->{'BillingState'} eq $_} ('AL', 'AK', 'AZ', 'AR', 'CA', 'CO', 'CT', 'DE', 'DC', 'FL', 'GA', 'HI', 'ID', 'IL', 'IN', 'IA', 'KS', 'KY', 'LA', 'ME', 'MD', 'MA', 'MI', 'MN', 'MS', 'MO', 'MT', 'NE', 'NV', 'NH', 'NJ', 'NM', 'NY', 'NC', 'ND', 'OH', 'OK', 'OR', 'PA', 'RI', 'SC', 'SD', 'TN', 'TX', 'UT', 'VT', 'VA', 'WA', 'WV', 'WI', 'WY')) {
			$errors->{'BillingState'} = 'No a valid 2 letter US State code';
			return $errors;
		}

	}

	if (scalar(keys %$errors) > 0) {
		return $errors;
	} else {
		return undef;
	}

}

1;
