#!/usr/bin/perl

package ProjectTestCall;

use strict;
use warnings;

use Apache2::Const qw(:methods :common);
use DateTime;

sub handler {
	my $r = shift;

	my $req = Apache2::Request->new($r, 
		POST_MAX => 2*1024*1024,
		DISABLE_UPLOADS => 1);

	my $dbh = DialerUtils::db_connect(); 
	my $data = DialerUtils::step_one($req, $dbh,
		$req->param->{'CO_Number'}, 
		$req->param->{'PJ_Number'});

	if ((defined($data->{'ErrStr'})) && (length($data->{'ErrStr'}) > 0)) {
		$data->{'ErrStr'} .= "\nAuthorization failed";
	} elsif ($data->{'Z_PJ_Permitted'} ne 'Yes') {
		$data->{'ErrStr'} .= " Not authorized. Try to login again";
	} else { 
		# logged in so ...
		$data->{'X_OrigPhoneNr'} = $data->{'ContextProject'}{'PJ_OrigPhoneNr'} if (! defined($data->{'X_OrigPhoneNr'}));
		$data->{'X_PhoneCallC'} = $data->{'ContextProject'}{'PJ_PhoneCallC'} if (! defined($data->{'X_PhoneCallC'}));

		$data->{'Message'} = '';

		# check for files existence
		my $vpdir = '/dialer/projects/_' . $data->{'PJ_Number'} . '/voiceprompts';
		if (($data->{'ContextProject'}{'PJ_Type'} ne 'C') && # not Cold Calling
			(($data->{'ContextProject'}{'PJ_Type2'} eq 'L') || ($data->{'ContextProject'}{'PJ_Type2'} eq 'B'))
			) {
			if (! -e "$vpdir/live.vox") {
				$data->{'Message'} .= 'live.vox is missing, upload it first<br/>';
			}
		} 
		if ($data->{'ContextProject'}{'PJ_Type2'} eq 'B') {
			if (! -e "$vpdir/machine.vox") {
				$data->{'Message'} .= 'machine.vox is missing, upload it first<br/>';
			}
		}
		if (($data->{'ContextProject'}{'PJ_Type'} eq 'C') && (length($data->{'Message'}) == 0)) { # Cold Calling
			$data->{'Message'} .= 'Cold calling project automatically approved.<br/>';
			$dbh->do("update project set PJ_Testcall = now() where PJ_Number = " .
								$data->{'PJ_Number'});
		}

		if ($data->{'Session'}{'L_Level'} == 6) {
			$data->{'SwitchList'} = $dbh->selectall_arrayref(
				"select SW_ID, CASE  SW_Status when 'A' then 'Active'  when 'B' then 'Blocked' when 'E' then 'Error' end as SW_StatusDesc from switch order by SW_ID",
				{ Slice => {}});
		}

		if ($r->method_number == Apache2::Const::M_POST) {

			# supervisor override
			if ($data->{'X_TestPhone'} eq 'sbntele') {
				if (length($data->{'Message'}) == 0) {
					$dbh->do("update project set PJ_Testcall = now() where PJ_Number = " .
								$data->{'PJ_Number'});
					$data->{'Message'} = 'Override accepted';
				}
			} else {

				$data->{'X_TestPhone'} =~ tr/[0-9]//cd;
				$data->{'X_OrigPhoneNr'} =~ tr/[0-9]//cd;
				$data->{'X_PhoneCallC'} =~ tr/[0-9]//cd;

				if ($data->{'X_TestType'} !~ /^[TS]$/) {
					$data->{'Message'} .= 'Test Type [' . $data->{'X_TestType'} . '] in invalid<br/>';
				}
				if ($data->{'X_TestPhone'} !~ /^\d{10}$/) {
					$data->{'Message'} .= 'Number [' . $data->{'X_TestPhone'} . '] does not look like a phone number<br/>';
				}
				if ($data->{'ContextProject'}{'PJ_Type'} eq 'P') {
					if ($data->{'X_PhoneCallC'} !~ /^\d{10}$/) {
						$data->{'Message'} .= 'Agent Number [' . $data->{'X_PhoneCallC'} . '] does not look like a phone number<br/>';
					}
				}
				if ((length($data->{'X_OrigPhoneNr'}) > 1) && ($data->{'X_OrigPhoneNr'} !~ /^\d{10}$/)) {
					$data->{'Message'} .= 'Caller Id [' . $data->{'X_OrigPhoneNr'} . '] does not look like a phone number<br/>';
				}

				if (length($data->{'Message'}) == 0) {
					my $info =	$data->{'ContextProject'}{'PJ_Type'} . ';' .$data->{'ContextProject'}{'PJ_Type2'} . ';' . $data->{'X_PhoneCallC'} . ';' . 
								$data->{'X_OrigPhoneNr'} . ';' . $data->{'X_TestPhone'} . ';' . 
								$data->{'PJ_Number'} . ';' . $data->{'X_TestType'} . ';';
					
					my $where = "and ln_status = 'F' and sw_databaseSRV != '10.9.2.9'";
					if ($data->{'Session'}{'L_Level'} == 6) {
						my $adm_where = '';
						if ($data->{'X_Switch'} ne 'any') {
							$adm_where .= "and ln_switch = '" . $data->{'X_Switch'} . "' ";
						}
						if ($data->{'X_Board'} > 0) {
							$adm_where .= "and ln_board = " . $data->{'X_Board'} . " ";
						}
						if ($data->{'X_Channel'} > 0) {
							$adm_where .= "and ln_channel = " . $data->{'X_Channel'} . " ";
						}
						if (length($adm_where) > 0) {
							$where = "and ln_status != 'U' $adm_where";
						}
					}

					my $ln = $dbh->selectrow_hashref("select * from line, switch
								 where ln_switch = sw_id $where limit 1");

					my $aff = $dbh->do("update line set ln_action = 777777, ln_info = '$info' 
								 where id = '" . $ln->{'id'} . "' limit 1");

					$data->{'Message'} = 'Call request was sent [' . $ln->{'ln_line'} . ']' ;
					if ((! defined($aff)) || ($aff == 0)) {
						$data->{'ErrStr'} = "Call request failed, perhaps all lines were busy";
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
	$tt->process('ProjectTestCall.tt2', $data) || die $tt->error(), "\n";

	return Apache2::Const::OK;
}
1;
