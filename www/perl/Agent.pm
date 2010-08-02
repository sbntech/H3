#!/usr/bin/perl

package Agent;

use strict;
use warnings;

use JSON;
use lib '/home/grant/H3/convert';
use Messenger;
use Apache2::Const qw(:methods :common);

sub valid_distrib_code {
	my $cd = shift;

	return $cd =~ /\w{32}/;
}

sub randstr {
	my $len = shift;
	my $rc = "";

	while (length($rc) < $len) {
		my $c = chr(48 + int(rand(76)));
		$rc .= $c if $c =~ /[0-9A-Za-z]/;
	}

	return $rc;
}

sub flog {

	# comment this line for debugging
	return;
	
	print STDERR "Agent.pm: ";
	print STDERR @_;
	print STDERR "\n";
}

sub logoff_byNumber {
	my $dbh = shift;
	my $AG_Number= shift;

	$dbh->do("update agent set 
			AG_SessionId = null, 
			AG_Paused = 'N',
			AG_Lst_change = now()
		where AG_Number = $AG_Number");
}

sub logoff {
	my $dbh = shift;
	my $AG_Name = shift;
	my $AG_Password = shift;

	$dbh->do("update agent set 
			AG_SessionId = null, 
			AG_Paused = 'N',
			AG_Lst_change = now()
		where AG_Password = '$AG_Password' 
		and upper(AG_Name) = '" . uc($AG_Name) . "'");

}

sub verify_login_credentials {
	my $dbh = shift;
	my $data = shift;
	my $req = shift;

	# sets $data->{'ErrorStr'} if there is a problem.

	# needs to be no pre-existing error
	return if defined($data->{'ErrorStr'});

	my $checkrow;
	my $redirect = 0;
	my $regularLogin = 0;
	my $sessionId;

	if ((defined($data->{'AG_Password'})) && (length($data->{'AG_Password'}) > 0)) {
		# ... using password
		$regularLogin = 1;
		flog("login attempt using password");

		$checkrow = $dbh->selectrow_hashref("select * from agent
				where AG_Password = '" .  $data->{'AG_Password'} . 
				"' and upper(AG_Name) = '" . uc($data->{'AG_Name'}) . 
				"' and AG_Status = 'A' and AG_MustLogin = 'Y'");

		if ((!defined($checkrow)) && (!defined($checkrow->{'AG_Number'}))) {
			$data->{'ErrorStr'} = "Login failed.";
			logoff($dbh, $data->{'AG_Name'}, $data->{'AG_Password'});
			return;
		}

		# check seat limits ...
		my $res = $dbh->selectrow_hashref("select CO_AuthorizedAgents,
			(select count(*) from agent where AG_Customer = CO_Number and AG_SessionId is not null) as LoggedIn
			from customer where CO_Number = " . $checkrow->{'AG_Customer'});

		if ((defined($res->{'CO_AuthorizedAgents'})) && (defined($res->{'LoggedIn'}))) {
			if ($res->{'CO_AuthorizedAgents'} < $res->{'LoggedIn'} + 1) {  # +1 for this attempt
				$data->{'ErrorStr'} = "Login aborted. Authorized agent seat limit " .
					$res->{'CO_AuthorizedAgents'} . ' exceeded.';
				logoff($dbh, $data->{'AG_Name'}, $data->{'AG_Password'});
				return;
			}
		} else {
			$data->{'ErrorStr'} = "Login failed, error determining authorized agent seat limit";
			logoff($dbh, $data->{'AG_Name'}, $data->{'AG_Password'});
			return;
		}

	} elsif (defined($req->jar)) {
		# ... using session cookie
		$sessionId = $req->jar->get('AGENTSESSID');
		if (! defined($sessionId)) {
			$data->{'ErrorStr'} = "Session expired";
			return;
		}

		flog("checking transaction with SessionID=$sessionId");

		$checkrow = $dbh->selectrow_hashref('select * from agent where ' .
			"AG_SessionId = '$sessionId' limit 1");

		if (! defined($checkrow->{'AG_Number'})) {
			$data->{'ErrorStr'} = "Session expired";
			return;
		} else {
		}
	} else {
		$data->{'ErrorStr'} = "No login credentials supplied";
		return;
	}

	# copy the agent columns
	for my $k (keys %$checkrow) {
		$data->{$k} = $checkrow->{$k};
	}

	my $PJ_Number = $checkrow->{'AG_Project'};

	# check that project is still runnable ...
	my $row = $dbh->selectrow_hashref("select * from project where PJ_Number = '$PJ_Number'");

	if (! defined($row->{'PJ_Number'})) {
		$data->{'ErrorStr'} = "Your project number ($PJ_Number) was bogus";
		logoff_byNumber($dbh, $checkrow->{'AG_Number'});
		return;
	} else {
		# copy the columns
		for my $k (keys %$row) {
			$data->{$k} = $row->{$k};
		}

		# ... unwrap PJ_DisposDescrip
		if (defined($row->{'PJ_DisposDescrip'})) {
			$data->{'X_Dispositions'} = JSON::from_json("[" . $row->{'PJ_DisposDescrip'} . "]");
		} else {
			$data->{'X_Dispositions'} = [ "None" ];
		}
	}

	if ((
			(($row->{'PJ_Type'} eq 'C') && ($row->{'PJ_timeleft'} ne 'Running*')) ||
			(($row->{'PJ_Type'} ne 'C') && ($row->{'PJ_timeleft'} ne 'Running'))
		) && ($row->{'PJ_timeleft'} ne 'No agents ready')) {

		$data->{'ErrorStr'} = "Your project is not runnable: " . $row->{'PJ_timeleft'};
		logoff_byNumber($dbh, $checkrow->{'AG_Number'});
		return;
	}

	if ($regularLogin) {
		# finalizing login using password
		flog("updating db to refelect good login");
		$sessionId = randstr(40);
		$redirect = 1;
		my $rows = $dbh->do("update agent set 
					AG_SessionId = '$sessionId', 
					AG_Lst_change = now()
				where AG_Password = '" .  $data->{'AG_Password'} . 
				"' and upper(AG_Name) = '" . uc($data->{'AG_Name'}) . 
				"' and AG_Status = 'A' and AG_MustLogin = 'Y'");
		if ((!defined($rows)) || ($rows == 0)) {
			$data->{'ErrorStr'} = "Login failed. Please verify your Name and Password and other settings";
			logoff_byNumber($dbh, $checkrow->{'AG_Number'});
			return;
		} elsif ($rows > 1) {
			$data->{'ErrorStr'} = "Login failed. Duplicate agent credentials";
			logoff_byNumber($dbh, $checkrow->{'AG_Number'});
			return;
		}
	}

	return ($sessionId, $redirect);
}

sub handler {
	my $r = shift;

	my $req = Apache2::Request->new($r, 
		POST_MAX => 10*1024,
		DISABLE_UPLOADS => 1);

	my $template = 'AgentLogin.tt2';
	my $sessionId;
	my %data;
	DialerUtils::formdata($req, \%data);
	my $dbh = DialerUtils::db_connect();

	if ((defined($data{'m'})) && ($data{'m'} eq 'login')) {
		$template = 'AgentLogin.tt2';
	} else {
		my ($sessionId, $redirect) = verify_login_credentials($dbh, \%data, $req);
		if ((defined($data{'ErrorStr'})) && (length($data{'ErrorStr'}) > 1)) {
			# some login error occurred
			flog("login error: " . $data{'ErrorStr'});

			if ((defined($data{'method'})) && ($data{'method'} eq 'poll')) {
					flog("poll response: logged off");
					$req->content_type('text/plain');
					print "-logged off-\n";
					$dbh->disconnect;
					return Apache2::Const::OK;
			}
		} else {
			if ($redirect) {
				my $cookie = Apache2::Cookie->new($r,
						 -name    =>  'AGENTSESSID',
						 -value   =>  $sessionId,
						 -expires =>  '+10h'
						);
				$cookie->bake($r);

				# redirect here to turn the POST into a GET
				$r->headers_out->add('Location' => '/pg/Agent');
				return Apache2::Const::REDIRECT;
			}

			$template = 'Agent.tt2';
			my $ccHost = DialerUtils::cc_host();

			if (defined($data{'method'})) {
				if ($data{'method'} eq 'process') {
					flog("processing the form for agent " . $data{'AG_Number'} . 
						" on project " . $data{'AG_Project'} . 
						" who was bridged to " . $data{'X_ProspectPhone'});

					# PopField0 ...
					my $popdata;
					my $sep = '';
					for (my $pi = 0; $pi < 100; $pi++) {
						last unless defined($data{"PopField$pi"});
						my $value = DialerUtils::escapeJSON($data{"PopField$pi"});
						$popdata .= "$sep\"$value\"";
						$sep = ",";
					}

					my $dnc = '';
					if ((defined($data{'DoNotCall'})) && ($data{'DoNotCall'} eq 'DNC')) {
						$dnc .= ", PN_DoNotCall = 'Y'";
						DialerUtils::custdnc_add($data{'PJ_CustNumber'}, 
							[ $data{'X_ProspectPhone'} ] # anonymous array ref
							);
						flog "Agent: " . $data{'AG_Number'} . " - " . $data{'AG_Name'} . 
								" added " . $data{'X_ProspectPhone'} . 
							" to the dnc list of customer " . $data{'PJ_CustNumber'};
					}
					my $numtbl = 'projectnumbers_' . $data{'AG_Project'};
					$data{'PN_Disposition'} = 0 unless $data{'PN_Disposition'};

					my $sth = $dbh->prepare("update $numtbl set 
						PN_Disposition = '" . $data{'PN_Disposition'} . "',
						PN_Notes = ?, PN_Popdata = ?$dnc
						where PN_PhoneNumber = '" . $data{'X_ProspectPhone'} . "'");

					$sth->execute($data{'PN_Notes'}, $popdata);

					if ($data{'PJ_Type'} eq 'C') {
						my $mq = Messenger::end_point($ccHost);
						$mq->send_msg('[ "nextcall", "' . $data{'AG_Project'} . '", "' . $data{'AG_Number'} . '", "' . $data{'X_ProspectPhone'} . '" ]');
					}
				} elsif ($data{'method'} eq 'transfer') {

					$dbh->disconnect;

					if ($data{'PJ_Type'} ne 'C') {
						return Apache2::Const::NOT_FOUND;
					}

					flog("transfer method for Agent " . $data{'AG_Number'} . 
						" on project " . $data{'AG_Project'} . 
						" bridged to " . $data{'X_ProspectPhone'} . 
						" transfer to " . $data{'X_TransferTo'} . 
						" (cc_host = $ccHost)");
					my $mq = Messenger::end_point($ccHost);
					$mq->send_msg('[ "transfer", "' . $data{'AG_Project'} . '", "' . $data{'AG_Number'} . 
									'", "' . $data{'X_ProspectPhone'} . '", "' . $data{'X_TransferTo'} . '" ]');
					print "ACK\n";
					return Apache2::Const::OK;
				} elsif ($data{'method'} eq 'hangup') {

					$dbh->disconnect;

					if ($data{'PJ_Type'} ne 'C') {
						return Apache2::Const::NOT_FOUND;
					}

					flog("hangup method for Agent " . $data{'AG_Number'} . 
						" on project " . $data{'AG_Project'} . 
						" bridged to " . $data{'X_ProspectPhone'} . 
						" (cc_host = $ccHost)");
					my $mq = Messenger::end_point($ccHost);
					$mq->send_msg('[ "hangup", "' . $data{'AG_Project'} . '", "' . $data{'AG_Number'} . '", "' . $data{'X_ProspectPhone'} . '" ]');
					print "ACK\n";
					return Apache2::Const::OK;
				} elsif ($data{'method'} eq 'poll') {
					# used in ajax call
					$req->content_type('text/plain');

					if (($data{'AG_QueueReady'} eq 'N') && ($data{'PJ_Type'} eq 'C')) {
						flog("poll response: not ready");
						print "-not ready-\n";
					} elsif (defined($data{'AG_BridgedTo'})) {
						if (($data{'LastNumber'}) eq $data{'AG_BridgedTo'}) {
							flog("poll response: no change");
							print "-no change-\n";
						} else {
							flog("poll: AG_BridgedTo=" . $data{'AG_BridgedTo'} . ", LastNumber=" . $data{'LastNumber'});
							# print popup data
							my $numtbl = 'projectnumbers_' . $data{'AG_Project'};
							my $dbrow = $dbh->selectrow_hashref("select $numtbl.*,NF_ColumnHeadings from $numtbl,
								numberfiles where PN_FileNumber = NF_FileNumber and
									PN_PhoneNumber = '" .	$data{'AG_BridgedTo'} . "' limit 1");

							my $popdata = {
								'PN_Disposition' => $dbrow->{'PN_Disposition'},
								'PN_Notes' => $dbrow->{'PN_Notes'},
								'PN_CallDT' => $dbrow->{'PN_CallDT'},
								'PN_Agent' => $dbrow->{'PN_Agent'},
								'AG_BridgedTo' => $data{'AG_BridgedTo'},
								'Loaded_Data' => {},
								'Loaded_Headings' => {},
								'Prev_AG_Name' => '',
							};

							if (defined($dbrow->{'PN_Popdata'})) {
								my $rdat = $dbrow->{'PN_Popdata'};
								$popdata->{'Loaded_Data'} = JSON::from_json("[$rdat]");
							}

							# ... unwrap headings
							if (defined($dbrow->{'NF_ColumnHeadings'})) {
								$popdata->{'Loaded_Headings'} = JSON::from_json("[" . $dbrow->{'NF_ColumnHeadings'} . "]");
							}

							if (!defined($data{'AG_BridgedTo'})) {
								$popdata->{'AG_BridgedTo'} = '0001110000000';
							}

							if ((defined($dbrow->{'PN_Agent'})) && ($dbrow->{'PN_Agent'} > 0) && ($dbrow->{'PN_Agent'} != 9999)) {
								if ($dbrow->{'PN_Agent'} == 1111) {
									$popdata->{'Prev_AG_Name'} = 'Call Center';
								} else {
									my $pa = $dbh->selectrow_hashref("select AG_Name from agent
										where AG_Number = " . $dbrow->{'PN_Agent'});
									$popdata->{'Prev_AG_Name'} = $pa->{'AG_Name'};
								}
							}

							my $pdata = JSON::to_json($popdata) . "\n";
							flog "popup: for agent " . $data{'AG_Number'} . " - " . $data{'AG_Name'} . " on project " .
								$data{'AG_Project'} . " for AG_BridgedTo=" . $data{'AG_BridgedTo'} .
								"\nJSON response:\n$pdata";

							print $pdata;

						}
					} else {
						flog("poll response: waiting");
						print "-waiting-\n";
					}

					$dbh->disconnect;
					return Apache2::Const::OK;

				} elsif ($data{'method'} eq 'logout') {
					# logout
					my $rows = $dbh->do("update agent set AG_Lst_change = now(),
						AG_SessionId = null, AG_BridgedTo = null, 
						AG_QueueReady = 'N', AG_Paused = 'N'
						where AG_Password = '" .  $data{'AG_Password'} . 
						"' and upper(AG_Name) = '" . uc($data{'AG_Name'}) . 
						"' and AG_SessionId = '" . $data{'AG_SessionId'} .
						"'");

					if ($data{'PJ_Type'} eq 'C') {
						my $mq = Messenger::end_point($ccHost);
						$mq->send_msg('[ "logoff", "' . $data{'AG_Project'} . '", "' . $data{'AG_Number'} . '", "0000000000" ]');
					}

					if ((!defined($rows)) || ($rows != 1)) {
						$data{'ErrorStr'} = "Failed to logout";
					}
					$template = 'AgentLogin.tt2';
				}
			}
		}
	}

	$dbh->disconnect;

	# render the page
	$req->content_type('text/html');
	my $tt = Template->new(INCLUDE_PATH => '/dialer/www/perl', ABSOLUTE => 1);
	$tt->process($template, \%data) || die $tt->error(), "\n";
	return Apache2::Const::OK;

}
1;
