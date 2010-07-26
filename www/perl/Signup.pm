#!/usr/bin/perl

package Signup;

use strict;
use warnings;

use Apache2::Const qw(:methods :common);

sub State2Timezone {
	my $st = uc(shift);

	return 0 unless defined $st;  # Eastern

	my @Pacific = qw(WA OR NV CA);
	my @Mountain = qw(MT ID WY UT CO AZ NM);
	my @Central = qw(ND SD NE KS OK TX MN WI IA IL MO AR MS AL LA);

	if (grep({ $st eq $_; } @Pacific)) {
		return -3;
	}

	if (grep({ $st eq $_; } @Mountain)) {
		return -2;
	}

	if (grep({ $st eq $_; } @Central)) {
		return -1;
	}

	return 0; # Eastern
}

sub random_password {

	my $pchars = "abcdefghijkmnpqrstuvwxyz98765432";
	my $plen = length($pchars);

	my $p;
	for (my $c = 0; $c < 7; $c++) {
		$p .= substr($pchars, int(rand($plen)), 1);
	}

	$p .= int(rand(100));

	return $p;
}

sub doSignup {
	my $data = shift;
	my $dbh = shift;

	# CO_Name
	if (!defined($data->{'CO_Name'})) {
		$data->{'ErrStr'} = 'A name was not supplied.';
		return;
	}

	my $CO_Name = $data->{'CO_Name'};
	$CO_Name =~ tr/'";//d; # clean it a bit
	
	if (length($CO_Name) < 3) {
		$data->{'ErrStr'} = 'Name is too short.';
		return;
	}

	my $ucheck = $dbh->selectrow_hashref("select count(*) as Count
		from customer where CO_Name = '$CO_Name'");
	
	if ((!defined($ucheck)) || (!defined($ucheck->{'Count'})) ||
		($ucheck->{'Count'} > 0)) {
		$data->{'ErrStr'} = 'Name is not unique.';
		return;
	}
	$data->{'CO_Name'} = $CO_Name;

	# CO_Email
	if (!defined($data->{'CO_Email'})) {
		$data->{'ErrStr'} = 'Email address missing';
		return;
	}

	my $CO_Email = $data->{'CO_Email'};
	$CO_Email =~ tr/'";//d; # clean it a bit
	if ($CO_Email !~ /(.{3,})@(.{2,}\..{2,})/) {
		$data->{'ErrStr'} = 'Email address looks bogus';
		return;
	}
	$data->{'CO_Email'} = $CO_Email;

	# other fields
	for my $fn ('CO_Address', 'CO_City', 'CO_Zipcode', 'CO_State',
		'CO_Tel', 'CO_Fax', 'CO_Contact') {
		if ((!defined($data->{$fn})) || (length($data->{$fn}) == 0)) {
			$data->{$fn} = 'not provided';
		}
	}

	$data->{'CO_Timezone'} = State2Timezone($data->{'CO_State'});
	$data->{'CO_Password'} = random_password();

	my $setClause = '';
	my $em = '';
	for my $fn ('CO_Address', 'CO_City', 'CO_Zipcode', 'CO_State',
		'CO_Tel', 'CO_Fax', 'CO_Email', 'CO_Timezone', 'CO_Password', 
		'CO_Name', 'CO_Contact') {

		my $val = $data->{$fn};
		$val =~ tr/'";//d; # clean it a bit

		$setClause .= "$fn = '" . $val . "', ";
		$em .= "    $fn: $val\n";
	}

	for my $fn (keys %{$data->{'Profile'}{'Defaults'}}) {
		my $val = $data->{'Profile'}{'Defaults'}{$fn};
		$setClause .= "$fn = '" . $val . "', ";
	}

	$dbh->do("insert into customer set $setClause CO_Status = 'A'");

	print STDERR "New Account Signup:\n$em";

	my $Subject = 'New Dialing Account Signup';
	$Subject = $data->{'Profile'}{'EmailSubject'} if defined($data->{'Profile'}{'EmailSubject'});

	my $BodyExtra = '';
	$BodyExtra = $data->{'Profile'}{'EmailBody'}  if defined($data->{'Profile'}{'EmailBody'});

	DialerUtils::send_email($CO_Email, 
		$data->{'Profile'}{'FromEmailAddress'},
		$Subject,
		"Login Page: " . $data->{'Profile'}{'LoginURL'} . 
		"\nUsername: $CO_Name\nPassword: " . $data->{'CO_Password'} . 
		"\n\n$BodyExtra");

	if (length($data->{'Profile'}{'SupportEmailAddress'}) > 0) {
		DialerUtils::send_email(
			$data->{'Profile'}{'SupportEmailAddress'}, 
			$data->{'Profile'}{'FromEmailAddress'},
			'New Account Signup', $em);
	}

}


sub handler {
	my $r = shift;

	my %Profiles = (
		'Testing' => {
				'SupportEmailAddress' => 'tech@sbndials.com',
				'FromEmailAddress' => 'root@sbndials.com',
				'LoginURL' => 'http://localhost/start.html',
				'TermsURL' => '/terms.html',
				'Defaults' => {
					'CO_Credit' => 4.99,
					'CO_Rate' => 0.05, 
					'CO_RoundBy' => 6,
					'CO_Min_Duration' => 60,
					'CO_Priority' => 9,
					'CO_Maxlines' => 200,
					'CO_Checknodial' => 'F',
					'CO_EnableMobile' => 'F',
					'CO_Billingtype' => 'T',
					'CO_AuthorizedAgents' => 1,
					'CO_AgentCharge' => 199.99,
					'CO_ResNumber' => 1 },
				'Response' => 'Human',
			},
		'BullseyeBroadcasting' => {
				'SupportEmailAddress' => 'Support@Bullseyebroadcast.com',
				'FromEmailAddress' => 'Support@Bullseyebroadcast.com',
				'LoginURL' => 'http://www.bullseyebroadcast.com/login.html',
				'TermsURL' => 'http://bullseyebroadcast.com/terms.html',
				'Defaults' => {
					'CO_Credit' => 5.0,
					'CO_Rate' => 0.05, 
					'CO_RoundBy' => 6,
					'CO_Min_Duration' => 6,
					'CO_Priority' => 9,
					'CO_Maxlines' => 200,
					'CO_Checknodial' => 'F',
					'CO_EnableMobile' => 'F',
					'CO_Billingtype' => 'T',
					'CO_AuthorizedAgents' => 1,
					'CO_AgentCharge' => 199.99,
					'CO_ResNumber' => 77},
				'Credit' => 5,
				'Response' => 'API',
				'EmailSubject' => 'Bullseye Broadcasting FREE TRIAL',
				'EmailBody' => "
Thank you for requesting a free predictive dialer trial from Bullseye Broadcasting. Your free trial will provide you with a \$5.00 Credit and full unrestricted use of all the robust capabilities of our Dialer system.

One of our knowledgeable staff members will be contacting you shortly to assist you with your free trial. Our representatives are available from 9am - 6pm EST, Monday through Friday. Feel Free to contact us directly with any questions. 866-916-7695

Click here for a Predictive Dialer training video: http://www.bullseyebroadcast.com/Video%20Training/PDS%20Training2.html
Click here for a Voice Broadcasting training video: http://www.bullseyebroadcast.com/Voice%20Broadcasting%20Training/VB%20Training.html

Thank you for your interest in Bullseye Broadcasting. 
We look forward to helping you reach your business goals.

Sincerely,
Bullseye Broadcasting",
			},
		'SBN' => {
				'SupportEmailAddress' => 'support@sbndials.com',
				'LoginURL' => 'http://w0.sbndials.com/start.html',
				'TermsURL' => '/terms.html',
				'Defaults' => {
					'CO_Credit' => 1.00,
					'CO_Rate' => 0.05, 
					'CO_RoundBy' => 6,
					'CO_Min_Duration' => 60,
					'CO_Priority' => 9,
					'CO_Maxlines' => 200,
					'CO_Checknodial' => 'F',
					'CO_EnableMobile' => 'F',
					'CO_Billingtype' => 'T',
					'CO_AuthorizedAgents' => 1,
					'CO_AgentCharge' => 199.99,
					'CO_ResNumber' => 1 },
				'Response' => 'Human',
			},
	);

	my $req = Apache2::Request->new($r, 
		POST_MAX => 10*1024,
		DISABLE_UPLOADS => 1);

	my $dbh = DialerUtils::db_connect();
	my $data = {};
	DialerUtils::formdata($req, $data);
	
	my $prof;
	if (defined($data->{'Profile'})) {
		$prof = $Profiles{$data->{'Profile'}};
		$data->{'ProfileName'} = $data->{'Profile'};
	}
	if (! defined($prof)) {
		$prof = $Profiles{'Testing'};
		$data->{'ProfileName'} = 'Testing';
	}
	$data->{'Profile'} = $prof; # name is replaced by actual profile

	if ($r->method_number == Apache2::Const::M_POST) {

		doSignup($data, $dbh);
		
		$data->{'Page'} = 'Response';
	} else {
		$data->{'Page'} = 'SignUpForm';
	}

	$dbh->disconnect;

	# render the page
	$req->content_type('text/html');
	my $tt = Template->new(INCLUDE_PATH => '/dialer/www/perl')
		|| die $Template::ERROR, "\n";
	$tt->process('Signup.tt2', $data) || die $tt->error(), "\n";

	return Apache2::Const::OK;
}
1;
