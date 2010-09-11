#!/usr/bin/perl

package Project;

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
	
	my @cols = (
			'PJ_Description',
			'PJ_CustNumber',
			'PJ_Status',
			'PJ_DateStart',
			'PJ_DateStop',
			'PJ_TimeStart',
			'PJ_TimeStartMin',
			'PJ_TimeStop',
			'PJ_TimeStopMin',
			'PJ_Type',
			'PJ_Maxline',
			'PJ_Type2',
			'PJ_PhoneCallC',
			'PJ_Local_Time_Start',
			'PJ_Local_Time_Stop',
			'PJ_Local_Start_Min',
			'PJ_Local_Stop_Min',
			'PJ_Maxday',
			'PJ_Weekend',
			'PJ_User',
			'PJ_Record',
			'PJ_OrigPhoneNr');

	$valid = 0 if required($data,'PJ_Description') == 0;

	# cleanse first
	for my $f (@cols) {
		if (defined($data->{$f})) {
			$data->{$f} =~ s/['"]//g;
			$data->{$f} =~ s/^\s*(.*)\s*$/$1/g; # trim
		}
	}

	# PJ_Number
	if (DialerUtils::is_blank_str($data->{'PJ_Number'})) {
		if ($data->{'X_Method'} eq 'Update') {
			$data->{'ErrStr'} = 'Project number was missing for Update';
			return undef; # no point continuing, this is serious
		}
	} else {
		if ($data->{'X_Method'} eq 'Insert') {
			$data->{'ErrStr'} = 'Project number cannot be provided for Insert';
			return undef; # no point continuing, this is serious
		}
	}

	# PJ_CustNumber
	if ($data->{'X_Method'} eq 'Update') {
		my $old = $dbh->selectrow_hashref("select PJ_CustNumber
			from project where PJ_Number = '" . $data->{'PJ_Number'}
			. "'");

		if ($old->{'PJ_CustNumber'} != $data->{'PJ_CustNumber'}) {
			$data->{'ErrStr'} = 'Cannot change customer like this';
			$valid = 0;
		}
	}

	# PJ_Status
	if (! DialerUtils::valid_values_str($data->{'PJ_Status'}, 'A', 'B')) {
		$data->{'PJ_Status_ERROR'} = 'Not a valid value';
		$valid = 0;
	}

	# PJ_DateStart
	my $startDT;
	if ($data->{'PJ_DateStart'} =~ /(\d{4})-(\d{2})-(\d{2})/) {
		my ($year, $month, $day) = ($1,$2,$3);
		$startDT = DateTime->new(year => $year, month => $month, day => $day);
		my $vstart = DateTime->now();
		$vstart->add( months => 1, days => 1 );

		$data->{'PJ_DateStart'} = $startDT->ymd; # canonicalize

		if (DateTime->compare($startDT,$vstart) == 1) {
			$data->{'PJ_DateStart_ERROR'} = 'Too far into future. 30 day limit.';
			$valid = 0;
		}
	} else {
		$data->{'PJ_DateStart_ERROR'} = 'Invalid date format, need YYYY-MM-DD';
		$valid = 0;
	}

	# PJ_DateStop
	if ($data->{'PJ_DateStop'} =~ /(\d{4})-(\d{2})-(\d{2})/) {
		my ($year, $month, $day) = ($1,$2,$3);
		my $dt = DateTime->new(year => $year, month => $month, day => $day);
		my $vstop = DateTime->now();
		$vstop->add( months => 6, days => 1 );

		$data->{'PJ_DateStop'} = $dt->ymd; # canonicalize

		if (DateTime->compare($dt,$vstop) == 1) {
			$data->{'PJ_DateStop_ERROR'} = 'Too far into future. 6 month limit.';
			$valid = 0;
		}

		if ((defined($startDT)) &&
			(DateTime->compare($startDT,$dt) == 1)) {
			$data->{'PJ_DateStop_ERROR'} = 'Must not be before start.';
			$valid = 0;
		}
			
	} else {
		$data->{'PJ_DateStop_ERROR'} = 'Invalid date format, need YYYY-MM-DD';
		$valid = 0;
	}

	# Workday (PJ_Workday_ERROR)
	($data->{'PJ_TimeStart'}, $data->{'PJ_TimeStartMin'}) =
		DialerUtils::splitTime($data->{'PJ_WorkdayStart'});
	my $workStart = DateTime->new(
		year => 2009, month => 1, day => 1,
		hour => $data->{'PJ_TimeStart'},
		minute => $data->{'PJ_TimeStartMin'},
		second => 0);

	($data->{'PJ_TimeStop'}, $data->{'PJ_TimeStopMin'}) =
		DialerUtils::splitTime($data->{'PJ_WorkdayStop'});
	my $workStop = DateTime->new(
		year => 2009, month => 1, day => 1,
		hour => $data->{'PJ_TimeStop'},
		minute => $data->{'PJ_TimeStopMin'},
		second => 59);

	if (DateTime->compare($workStart, $workStop) == 1) {
		$data->{'PJ_Workday_ERROR'} = 'Must start before stops';
		$valid = 0;
	}

	# PJ_Type
	if (! DialerUtils::valid_values_str($data->{'PJ_Type'}, 'C', 'P', 'S', 'A')) {
		$data->{'PJ_Type_ERROR'} = 'Not a valid value';
		$valid = 0;
	}

	# PJ_Maxline
	$data->{'PJ_Maxline'} = DialerUtils::make_an_int($data->{'PJ_Maxline'});
	if ($data->{'PJ_Type'} eq 'C') {
		# cold calling
		$data->{'PJ_Maxline'} = 1;
	} else {
		if ($data->{'PJ_Maxline'} <= 0) {
			$data->{'PJ_Maxline_ERROR'} = 'Must be > 0';
			$valid = 0;
		}
	}

	# PJ_Type2
	if (! DialerUtils::valid_values_str($data->{'PJ_Type2'}, 'L', 'B')) {
		$data->{'PJ_Type2_ERROR'} = 'Not a valid value';
		$valid = 0;
	}

	# PJ_Testcall
	if ((! defined($data->{'PJ_Testcall'})) ||
		(DialerUtils::is_blank_str($data->{'PJ_Testcall'})) || 
		($data->{'PJ_Testcall'} eq '0000-00-00 00:00:00')) {
		if ($data->{'PJ_Status'} eq 'A') {
			$data->{'PJ_Testcall_ERROR'} = 'Active projects need a test call';
			$data->{'PJ_Status_ERROR'} = 'Cannot activate without a test call';
			$valid = 0;
		}
	}

	# PJ_timeleft - no validation

	# PJ_Visible
	if (! DialerUtils::valid_values_str($data->{'PJ_Visible'}, '1', '0')) {
		$data->{'PJ_Visible'} = 1;
	}

	# PJ_Record
	if (! DialerUtils::valid_values_str($data->{'PJ_Record'}, 'Y', 'N')) {
		$data->{'PJ_Record'} = 'N';
	}

	# PJ_PhoneCallC
	my $cc = DialerUtils::north_american_phnumber($data->{'PJ_PhoneCallC'});
	if ($data->{'PJ_Type'} eq 'P') {
		if (length($cc) > 0) {
			if (length($cc) == 10) {
				$data->{'PJ_PhoneCallC'} = $cc;
				if ($cc =~ /^(800|888|866|877)/) {
					$data->{'PJ_PhoneCallC_ERROR'} = 
						'Cannot be toll free';
					$valid = 0;
				}
			} else {
				$data->{'PJ_PhoneCallC_ERROR'} = 
					'Invalid north american phone number';
				$valid = 0;
			}
			
		} else {
			$data->{'PJ_PhoneCallC'} = '';
		}
	} else {
		$data->{'PJ_PhoneCallC'} = '';
	}

	# Prospect (PJ_Prospect_ERROR)
	($data->{'PJ_Local_Time_Start'}, $data->{'PJ_Local_Start_Min'}) =
		DialerUtils::splitTime($data->{'PJ_ProspectStart'});
	my $prospectStart = DateTime->new(
		year => 2009, month => 1, day => 1,
		hour => $data->{'PJ_Local_Time_Start'},
		minute => $data->{'PJ_Local_Start_Min'},
		second => 0);

	($data->{'PJ_Local_Time_Stop'}, $data->{'PJ_Local_Stop_Min'}) =
		DialerUtils::splitTime($data->{'PJ_ProspectStop'});
	my $prospectStop = DateTime->new(
		year => 2009, month => 1, day => 1,
		hour => $data->{'PJ_Local_Time_Stop'},
		minute => $data->{'PJ_Local_Stop_Min'},
		second => 59);

	if (DateTime->compare($prospectStart, $prospectStop) == 1) {
		$data->{'PJ_Prospect_ERROR'} = 'Must start before stops';
		$valid = 0;
	}

	# PJ_Maxday
	$data->{'PJ_Maxday'} = DialerUtils::make_an_int($data->{'PJ_Maxday'});
	if ($data->{'PJ_Maxday'} < 0) {
		$data->{'PJ_Maxday_ERROR'} = 'Must be >= 0';
		$valid = 0;
	}

	# PJ_Weekend
	if (! DialerUtils::valid_values_str($data->{'PJ_Weekend'}, '0', '1', '2', '3')) {
		$data->{'PJ_Weekend_ERROR'} = 'Not a valid value';
		$valid = 0;
	}

	# PJ_User - left to the UI for now
	$data->{'PJ_User'} = '' if (! defined($data->{'PJ_User'}));

	# PJ_OrigPhoneNr - left to the UI for now
	$data->{'PJ_OrigPhoneNr'} = '' if (! defined($data->{'PJ_OrigPhoneNr'}));

	# PJ_DisposDescrip (non-normalized)
	if ($data->{'PJ_Type'} eq 'C') {
		my $s = '';
		for my $i (0,1,2,3,4,5,6,7,8,9) {
			$s .= ',' if $i > 0;
			my $disp = $data->{"X_Disposition$i"};
			if (defined($disp)) {
				$s .= "\"" . DialerUtils::escapeJSON($disp) . "\"";
			} else {
				$s .= '""';
			}
		}
		$data->{'PJ_DisposDescrip'} = $s;
	} else {
		$data->{'PJ_DisposDescrip'} = '';
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
		return "insert into project ($flist,PJ_timeleft,PJ_Support,PJ_DisposDescrip, PJ_CallScript) values ($fval,'New','C',?,?)";
	} else {
		return "update project set $set, PJ_DisposDescrip = ?, PJ_CallScript = ? where " .
			"PJ_Number = " . $data->{'PJ_Number'};
	}
}

sub to_list {
	my $r = shift;
	my $data = shift;
	# return to list
	$r->content_type('text/html');
	print "<html><head><script>window.location='/pg/ProjectList?CO_Number=" .
		$data->{'CO_Number'};
		
	if (defined($data->{'PJ_Number'})) {
		print "&PJ_Number=" . $data->{'PJ_Number'};
	}
	print "'</script></head><body/></html>";

	return Apache2::Const::OK;
}

sub load_more_data {
	my $dbh = shift;
	my $data = shift;

	# make nice time zones
	my %TZ_lookup = ('0' => 'Eastern', '-1' => 'Central', 
		'-2' => 'Mountain', '-3' => 'Pacific');
	$data->{'X_TZ_String'} = $TZ_lookup{$data->{'ContextCustomer'}{'CO_Timezone'}};

	# CID
	my $res = $dbh->selectall_arrayref("select CC_Callerid 
		from custcallerid where CC_Customer = '" .
		$data->{'CO_Number'} . "'");

	for my $row (@$res) {
		my $CID = $row->[0];
		push @{$data->{'X_CustomerCIDs'}}, $CID;
	}

	# Users		
	$data->{'X_Users'} = $dbh->selectall_arrayref("select * 
		from users where us_customer = '" .
		$data->{'CO_Number'} . "'",
		{ Slice => {}});
}


sub handler {
	my $r = shift;

	my $req = Apache2::Request->new($r, 
		POST_MAX => 10*1024,
		DISABLE_UPLOADS => 1);

	my $dbh = DialerUtils::db_connect(); 
	my $data = DialerUtils::step_one($req, $dbh,
		$req->param->{'CO_Number'}, 
		$req->param->{'PJ_Number'});

	my $res;

	if ((defined($data->{'ErrStr'})) && (length($data->{'ErrStr'}) > 0)) {
		$data->{'ErrStr'} .= "\nAuthorization failed";
	} elsif (!defined($data->{'X_Method'})) {
		$data->{'ErrStr'} = "X_Method parameter not specified";
	} elsif ($data->{'Z_CO_Permitted'} ne 'Yes') {
		$data->{'ErrStr'} .= " Not authorized. Try to login again";
	} elsif ((defined($req->param->{'PJ_Number'})) && (!DialerUtils::is_blank_str($req->param->{'PJ_Number'}))) {
		if ($data->{'X_Method'} eq 'New') {
			$data->{'ErrStr'} = "Do not supply a PJ_Number when X_Method = New";
		} elsif ($data->{'Z_PJ_Permitted'} ne 'Yes') {
			$data->{'ErrStr'} .= " Not authorized on this project. Try to login again";
		} else {
			# load read-only values
			$res = $dbh->selectrow_hashref(
				"select PJ_CustNumber, PJ_Testcall from project where 
				PJ_Number = " . $data->{'PJ_Number'});

			if ($res) {
				for my $ro (keys %$res) {
					$data->{$ro} = $res->{$ro};
				}
			} else {
				# should be impossible - since step_one would have caught it
				$data->{'ErrStr'} = "No such project " . $data->{'PJ_Number'};
			}
		}
	}

	# determine OnlyColdCall ...
	$res = $dbh->selectrow_hashref("select RS_OnlyColdCall from reseller
		where RS_Number = '" . $data->{'ContextCustomer'}{'CO_ResNumber'}
		. "' limit 1");
	$data->{'OnlyColdCall'} = $res->{'RS_OnlyColdCall'};
	if (($res->{'RS_OnlyColdCall'} eq 'N') &&
		($data->{'ContextCustomer'}{'CO_OnlyColdCall'} eq 'Y')) {

		$data->{'OnlyColdCall'} = 'Y';
	}

	if (length($data->{'ErrStr'}) == 0) {
		# logged in so ...

		if ($data->{'X_Method'} eq 'Delete') {
			$dbh->do("update project set PJ_Visible = 0, PJ_Support = 'C' where
				PJ_Number = '" . $req->param->{'PJ_Number'} . "' limit 1");
			return to_list($r, $data);
		} elsif ($data->{'X_Method'} eq 'Pause') {
			$dbh->do("update project set PJ_Status = 'B', PJ_Timeleft = 'Paused' where
				PJ_CustNumber = '" . $req->param->{'CO_Number'} . "' and PJ_Status = 'A'");
			return to_list($r, $data);
		} elsif ($data->{'X_Method'} eq 'Resume') {
			$dbh->do("update project set PJ_Status = 'A', PJ_Timeleft = 'Resumed' where
				PJ_CustNumber = '" . $req->param->{'CO_Number'} . "'  and PJ_Status = 'B'
				and PJ_Timeleft = 'Paused'");
			return to_list($r, $data);
		} elsif (($data->{'X_Method'} eq 'Insert') || ($data->{'X_Method'} eq 'Update')) {
			my $sql = make_sql($data, $dbh);
			if (defined($sql)) {
				my $sth = $dbh->prepare($sql);
				my $rc = $sth->execute($data->{'PJ_DisposDescrip'}, $data->{'PJ_CallScript'});
				if (! $rc) {
					$data->{'ErrStr'} = "Failed: " . $dbh->errstr;
				} else {
					if ($data->{'X_Method'} eq 'Insert') {
						$data->{'PJ_Number'} = $dbh->last_insert_id(undef,undef,undef,undef);

					}
					# create the project directories, if needed
					my $pdir = '/dialer/projects/_' . $data->{'PJ_Number'};
					for my $dir ("$pdir", "$pdir/voiceprompts", "$pdir/recordings", "$pdir/cdr") {
						if (! -d $dir) {
							system("/usr/bin/install --mode=0777 --group=www-data --owner=www-data -d $dir");
						}
					}

					return to_list($r, $data);
				}
			}
		} elsif ($data->{'X_Method'} eq 'Edit') {

			load_more_data($dbh, $data);

			# copy values
			for my $k (keys %{$data->{'ContextProject'}}) {
				$data->{$k} = $data->{'ContextProject'}{$k};
			}

			$data->{'X_Method'} = 'Update';

			# work day mangling
			$data->{'PJ_WorkdayStart'} = 
				DialerUtils::buildTime($data->{'PJ_TimeStart'}, $data->{'PJ_TimeStartMin'});
			$data->{'PJ_WorkdayStop'} = 
				DialerUtils::buildTime($data->{'PJ_TimeStop'}, $data->{'PJ_TimeStopMin'});	

			# prospect tx mangling
			$data->{'PJ_ProspectStart'} = 
				DialerUtils::buildTime($data->{'PJ_Local_Time_Start'}, $data->{'PJ_Local_Start_Min'});
			$data->{'PJ_ProspectStop'} = 
				DialerUtils::buildTime($data->{'PJ_Local_Time_Stop'}, $data->{'PJ_Local_Stop_Min'});

			# Disposition mangling
			for (my $i = 0; $i < 10; $i++) {
				$data->{"X_Disposition$i"} = '';
			}
			if (defined($data->{'PJ_DisposDescrip'})) {
				my $d = JSON::from_json("[" . $data->{'PJ_DisposDescrip'} . "]");
				my $c = 0;
				for my $e (@$d) {
					$data->{"X_Disposition$c"} = $e;
					$c++;
				}
			}
		} elsif ($data->{'X_Method'} eq 'New') {
			my ($nowd, $nowt) = DialerUtils::local_datetime();
			my ($stopd, $stopt) = DialerUtils::local_datetime(time() + (14*24*60*60));
			
			load_more_data($dbh, $data);

			# returns a new empty project
			$data->{'X_Method'} = 'Insert';

			$data->{'PJ_CustNumber'} = $data->{'ContextCustomer'}{'CO_Number'};

			$data->{'PJ_Description'} = "";
			$data->{'PJ_Status'} = "B";
			$data->{'PJ_DateStart'} = $nowd; 
			$data->{'PJ_DateStop'} = $stopd; 

			$data->{'PJ_WorkdayStart'} = "08:00AM";
			$data->{'PJ_WorkdayStop'} = "06:00PM";
			$data->{'PJ_ProspectStart'} = "09:00AM";
			$data->{'PJ_ProspectStop'} = "09:00PM";

			$data->{'PJ_Type'} = "C";
			$data->{'PJ_Maxline'} = "5";
			$data->{'PJ_Type2'} = "L";
			$data->{'PJ_Testcall'} = "";
			$data->{'PJ_timeleft'} = "New";
			$data->{'PJ_Visible'} = "1";
			$data->{'PJ_PhoneCallC'} = "";

			$data->{'PJ_Maxday'} = "0";
			$data->{'PJ_Weekend'} = "0";
			if ($data->{'Session'}{'L_Level'} < 3) {
				$data->{'PJ_User'} = $data->{'Session'}{'L_Number'};
			} else {
				$data->{'PJ_User'} = "";
			}
			$data->{'PJ_OrigPhoneNr'} = "";
			$data->{'PJ_LastCall'} = "";

			$data->{'X_Disposition0'} = 'None';
			$data->{'X_Disposition1'} = 'Not Interested';
			$data->{'X_Disposition2'} = 'Interested';
			$data->{'X_Disposition3'} = 'Call Back';
			$data->{'X_Disposition4'} = 'Wrong Number';
			$data->{'X_Disposition5'} = 'Answering Machine';
			$data->{'X_Disposition6'} = 'Sale Closed';
			$data->{'X_Disposition7'} = '';
			$data->{'X_Disposition8'} = '';
			$data->{'X_Disposition9'} = '';
		} else {
			$data->{'ErrStr'} = "Method " . $data->{'X_Method'} .
				" is not implemented";
		}
	}
	$dbh->disconnect;

	# render the page
	$req->content_type('text/html');
	my $tt = Template->new(INCLUDE_PATH => '/dialer/www/perl')
		|| die $Template::ERROR, "\n";
	$tt->process('Project.tt2', $data) || die $tt->error(), "\n";

	return Apache2::Const::OK;
}
1;
