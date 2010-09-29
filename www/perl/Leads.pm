#!/usr/bin/perl

package Leads;

use strict;
use warnings;

use Apache2::Const qw(:methods :common);
use Time::HiRes qw( gettimeofday tv_interval );
use JSON;

sub upload {
	my $dbh = shift;
	my $req = shift;
	my $data = shift;
	
	my $sep = "";
	my $flist = "";

	use File::Temp qw/ tempdir /;

	for my $n ($req->upload) {
		my $u = $req->upload($n);
		next if ($u->size <= 0);

		# IE sends names like P:\mydir\myfile.txt
		my $base = $u->filename;
		$base =~ s/.*(\\|\/)(.*)/$2/;

		if ($base =~ /\.zip$/i) {
			# unzip and convert each file
			my $dir = tempdir(DIR => '/tmp/LoadLeads');
			system("unzip -q -j -d $dir " . $u->tempname);
			chmod(0777, $dir); # to allow mysql access

			opendir(ZD, $dir) or die "opening zip dir $dir failed: $!";
			for my $f (grep !/^\./, readdir(ZD)) {
				$data->{'NF_FileName'} = $f;
				$data->{'NF_FileName'} =~ tr/'"//d;
				$flist .= "$sep$f"; $sep = ", ";
				my $JobId = rand();
				DialerUtils::move_leads("$dir/$f", "/dialer/projects/workqueue/LoadLeads-DATA-$JobId");
				open JFILE, '>', "/tmp/LoadLeads-JSON-$JobId" or die "opening failed: $!";
				print JFILE JSON::to_json($data);
				close JFILE;
				DialerUtils::move_leads("/tmp/LoadLeads-JSON-$JobId", "/dialer/projects/workqueue/");
			}
			closedir(ZD);
			system("rm -r $dir");
		} else {
			my $JobId = rand();
			$data->{'NF_FileName'} = $base;
			$data->{'NF_FileName'} =~ tr/'"//d;
			$flist = "$sep$base";
			DialerUtils::move_leads($u->tempname, "/dialer/projects/workqueue/LoadLeads-DATA-$JobId");
			open JFILE, '>', "/tmp/LoadLeads-JSON-$JobId" or die "opening failed: $!";
			print JFILE JSON::to_json($data);
			close JFILE;
			DialerUtils::move_leads("/tmp/LoadLeads-JSON-$JobId", "/dialer/projects/workqueue/");
		}
	}

	return $flist;
}

sub redial_machines {
	my $req = shift;
	my $data = shift;
	my $dbh = shift;

	my $FileNumber = $data->{'filenumber'};

	my $aff = $dbh->do('update projectnumbers_' . $data->{'PJ_Number'} . " set PN_Status = 'R',
		PN_Seq = PN_Seq + floor(rand()*100000)
		where PN_Status = 'X' and PN_DoNotCall != 'Y' 
		and substr(PN_CallResult,1,1) = 'M' and PN_FileNumber = '$FileNumber'");

	$aff = 0 unless $aff;
	return sprintf('%d machine numbers flagged for redialing', $aff);
}

sub redial_lives {
	my $req = shift;
	my $data = shift;
	my $dbh = shift;

	my $FileNumber = $data->{'filenumber'};

	my $aff = $dbh->do('update projectnumbers_' . $data->{'PJ_Number'} . " set PN_Status = 'R',
		PN_Seq = PN_Seq + floor(rand()*100000)
		where PN_Status = 'X' and PN_DoNotCall != 'Y' 
		and substr(PN_CallResult,1,1) = 'H' and PN_FileNumber = '$FileNumber'");

	$aff = 0 unless $aff;
	return sprintf('%d live numbers flagged for redialing', $aff);
}

sub redial_nonconn {
	my $req = shift;
	my $data = shift;
	my $dbh = shift;

	my $FileNumber = $data->{'filenumber'};

	my $aff = $dbh->do('update projectnumbers_' . $data->{'PJ_Number'} . " set PN_Status = 'R',
		PN_Seq = PN_Seq + floor(rand()*100000)
		where PN_Status = 'X' 
		and PN_DoNotCall != 'Y'
		and substr(PN_CallResult,1,1) != 'H' 
		and substr(PN_CallResult,1,1) != 'M' 
		and PN_FileNumber = '$FileNumber'");

	$aff = 0 unless $aff;
	return sprintf('%d non-connected numbers flagged for redialing', $aff);
}

sub redial_disp {
	my $req = shift;
	my $data = shift;
	my $dbh = shift;
	my $disp = shift;

	my $FileNumber = $data->{'filenumber'};

	my $aff = $dbh->do('update projectnumbers_' . $data->{'PJ_Number'} . " set PN_Status = 'R',
		PN_Seq = PN_Seq + floor(rand()*100000)
		where PN_Status = 'X' 
		and PN_DoNotCall != 'Y'
		and PN_Disposition = '$disp' 
		and PN_FileNumber = '$FileNumber'");

	$aff = 0 unless $aff;
	return sprintf('%d numbers with disposition=%d flagged for redialing', $aff, $disp);
}

sub download {
	my $req = shift;
	my $data = shift;
	my $dbh = shift;

	# download a list
	my $fn = 'NF-' . $data->{'filenumber'};

	# write out PHONE heading
	my $line1 = "Phone,Notes,Disposition,Call Result,Call Date,Do Not Call,Agent,Survey Results";

	# write out other headings (if they exist)
	my $pdata = '';
	my $nf = $dbh->selectrow_hashref("select *
					from numberfiles where NF_FileNumber = '" .
					$data->{'filenumber'} . "' limit 1");

	if (defined($nf->{'NF_ColumnHeadings'})) {
		# parse it to effect an unescape
		my $Headings = JSON::from_json("[" . $nf->{'NF_ColumnHeadings'} . "]");
		for my $h (@$Headings) {
			$line1 .= ",\"$h\"";
		}
		$pdata = ", PN_Popdata ";
	}

	my $tmp = "/tmp/$fn.heading";
	if (! open(HEADING, '>', $tmp)) {
		return("Failed to created temp file $tmp: $!", undef);
	}

	print HEADING "$line1\n";
	close HEADING;

	# write PN_PhoneNumber, PN_Popdata
	my $target = "/tmp/$fn.csvdata";
	my $dumpf = "/var/lib/mysql/dialer/DOWNLOAD-$fn.csvdata";
	$dbh->do("select PN_PhoneNumber,
		IF(PN_Notes is null,'',PN_Notes),
		IF(PN_Disposition is null,'',PN_Disposition),
		IF(PN_CallResult is null,'',PN_CallResult),
		IF(PN_CallDT is null,'',PN_CallDT),
		IF(PN_DoNotCall is null,'',PN_DoNotCall),
		IF(PN_Agent is null,'',PN_Agent),
		IF(PN_SurveyResults is null,'',PN_SurveyResults) $pdata
		from `projectnumbers_" .
		$data->{'PJ_Number'} . "` where PN_FileNumber = '" .
		$data->{'filenumber'} . "' into outfile '$dumpf'
		fields escaped by '' terminated by ',' optionally enclosed by '' lines terminated by '\\n'");
	DialerUtils::move_from_db($dumpf, $target);

	system("cat $tmp $target > /tmp/$fn.csv");
	my $zip = "/tmp/$fn.zip";
	system("zip -q -j $zip /tmp/$fn.csv");
	unlink($tmp);
	unlink($target);
	unlink("/tmp/$fn.csv");

	return (undef, $zip, $nf->{'NF_FileName'});
}

sub edit_headers {
	my $req = shift;
	my $data = shift;
	my $dbh = shift;

	my $FileNumber = $data->{'filenumber'};

	return "Numbersfile.tt2";

}

sub update_nfile {
	my $req = shift;
	my $data = shift;
	my $dbh = shift;

	my $HeadingCount = $data->{'X_HeadingCount'};
	
	if ((!defined($HeadingCount)) || ($HeadingCount == 0)) {
		return;
	}

	# pack headings (non-normalized)
	my $s = '';
	for (my $i = 1; $i <= $HeadingCount; $i++) {
		$s .= ',' if $i > 1;
		my $hdr = $data->{"X_Heading$i"};
		if ((defined($hdr)) && (length($hdr) > 0)) {
			$s .= "\"" . DialerUtils::escapeJSON($hdr) . "\"";
		} else {
			$s .= '"' . $i . '"';
		}
	}

	my $FileNumber = $data->{'filenumber'};

	my $sth = $dbh->prepare('update numberfiles
		set NF_ColumnHeadings = ? where NF_Project = ' . 
		$data->{'PJ_Number'} ." and NF_FileNumber = '$FileNumber'");

	if ($sth->execute($s)) {
		return "Headings updated";
	} else {
		return "Headings failted to update";
	}
}

sub report_callresults {
	my $req = shift;
	my $data = shift;
	my $dbh = shift;

	my $FileNumber = $data->{'filenumber'};

	my %DispositionDescriptions = (
			'XC' => 'Scrubbed Customer DNC',
			'XM' => 'Scrubbed Main Dnc',
			'XR' => 'Scrubbed No Carrier Route',
			'XP' => 'Scrubbed Mobile Phone',
			'XN' => 'Scrubbed Non-connect',
			'XX' => 'Scrubbed Militant',
			'XF' => 'Scrubbed Limited Footprint',
			'XD' => 'Scrubbed Duplicate',
			'XE' => 'Scrubbed No Carrier Route',  # expensive
			'HA' => 'Live person answered',
			'HU' => 'Live person short call',
			'HN' => 'Live person hangup',
			'MA' => 'Machine answered',
			'MN' => 'Machine answered hangup',
			'NA' => 'No answer',
			'BU' => 'Busy',
			'BA' => 'Bad',
			'FA' => 'Fax',
			'AC' => 'Agent connected',
			'AB' => 'Agent busy',
			'AN' => 'Agent no-answer',
			'DA' => 'Agent got dead air',
			'AS' => 'Agent stand-by',
	);

	$data->{'CallResultHistogram'} = $dbh->selectall_arrayref(
		'select count(*) as Count, PN_CallResult from
		projectnumbers_' . $data->{'PJ_Number'} . "
		where PN_FileNumber = '$FileNumber'
		and PN_CallResult is not null
		group by PN_CallResult",
		{ Slice => {}});

	for my $r (@{$data->{'CallResultHistogram'}}) {
		my $d = $DispositionDescriptions{$r->{'PN_CallResult'}};
		$d = 'Unknown' unless defined($d);
		$r->{'Description'} = $d;
	}

	return "LeadsReport1.tt2";
}

sub report_timezone {
	my $req = shift;
	my $data = shift;
	my $dbh = shift;

	my $FileNumber = $data->{'filenumber'};

	my %Descriptions = (
			'0' => 'Eastern',
			'1' => 'Central',
			'2' => 'Mountain',
			'3' => 'Pacific',
			'4' => 'Alaskan',
			'5' => 'Hawaii',
			'6' => 'Other',
			'7' => 'Other',
			'8' => 'Other',
			'9' => 'Other',
			'10' => 'Other',
			'11' => 'Other',
			'12' => 'Other',
			'13' => 'Other',
			'14' => 'Other',
			'15' => 'Other',
			'16' => 'Other',
			'17' => 'Other',
			'18' => 'Other',
			'19' => 'Other',
			'20' => 'Other',
			'21' => 'Other',
			'22' => 'Other',
			'23' => 'Other',
	);

	$data->{'TimezoneHistogram'} = $dbh->selectall_arrayref(
		'select count(*) as Count, PN_Timezone from
		projectnumbers_' . $data->{'PJ_Number'} . "
		where PN_FileNumber = '$FileNumber'
		and PN_Status != 'X'
		group by PN_Timezone",
		{ Slice => {}});

	for my $r (@{$data->{'TimezoneHistogram'}}) {
		my $d = $Descriptions{$r->{'PN_Timezone'}};
		$d = 'Unknown' unless defined($d);
		$r->{'Description'} = $d;
	}

	return "LeadsReport2.tt2";
}

sub report_disposition {
	my $req = shift;
	my $data = shift;
	my $dbh = shift;

	my $FileNumber = $data->{'filenumber'};

	my $res = $dbh->selectall_arrayref(
		'select count(*) as Count, PN_Agent, PN_Disposition from
		projectnumbers_' . $data->{'PJ_Number'} . "
		where PN_FileNumber = '$FileNumber'
		and PN_Agent is not null
		and PN_Agent != 9999 
		group by PN_Agent, PN_Disposition
		order by PN_Agent, PN_Disposition",
		{ Slice => {}});

	my %Histo;
	my %DispTotals;
	for my $row (@$res) {
		$DispTotals{'Total'} +=
			$row->{'Count'};
		$DispTotals{$row->{'PN_Disposition'}} +=
			$row->{'Count'};
		$Histo{$row->{'PN_Agent'}}{$row->{'PN_Disposition'}} =
			$row->{'Count'};
		$Histo{$row->{'PN_Agent'}}{'Total'} +=
			$row->{'Count'};
	}
	$data->{'Dispogram'} = \%Histo;
	$data->{'DispTotals'} = \%DispTotals;

	# agent names
	my $ag = $dbh->selectall_arrayref(
		"select AG_Number, AG_Name from agent
		where AG_Customer = '" . $data->{'CO_Number'} .
		"'", { Slice => {}});

	for my $row (@$ag) {
		$data->{'Agents'}{$row->{'AG_Number'}} = $row->{'AG_Name'};
	}
	$data->{'Agents'}{1111} = 'Call Center';
	$data->{'Agents'}{9999} = 'Prospect';

	# Note: disposition descriptions in X_Dispositions

	return "LeadsReport3.tt2";
}

sub delfile {
	my $req = shift;
	my $data = shift;
	my $dbh = shift;

	my @log;
	my $tv_start = [gettimeofday()];
	my $FileNumber = $data->{'filenumber'};

	my $aff1 = $dbh->do('delete from projectnumbers_' . $data->{'PJ_Number'} .
		" where PN_FileNumber = '$FileNumber'");

	my $aff2 = $dbh->do('delete from numberfiles where NF_Project = ' . $data->{'PJ_Number'} .
		" and NF_FileNumber = '$FileNumber'");

	$aff1 = 0 unless $aff1;
	$aff2 = 0 unless $aff2;
	return sprintf('%d numbers in %d file deleted', $aff1, $aff2);
}

sub apiload {
	my $req = shift;
	my $dbh = shift;
	my $http_method = shift;
	my $data;
	my $apiMessage;

	my $CO_Number = DialerUtils::make_an_int($req->param->{'CO_Number'});
	my $PJ_Number = DialerUtils::make_an_int($req->param->{'PJ_Number'});

	# API_Password
	if ($http_method != Apache2::Const::M_POST) {
		$apiMessage = "Expected HTTP POST method";
	} elsif ((! defined($req->param->{'API_Password'})) ||
		($req->param->{'API_Password'} ne '2Z3E!l1oO0Qqg')) {
		$apiMessage = "Authentication error";
	} elsif ($CO_Number <= 0) {
		$apiMessage = "CO_Number was not valid";
	} elsif ($PJ_Number <= 0) {
		$apiMessage = "PJ_Number was not valid";
	} elsif (! (defined($req->param->{'maindncscrub'}))) {
		$apiMessage = "maindncscrub was not defined";
	} elsif (($req->param->{'maindncscrub'} ne 'Y') &&
			 ($req->param->{'maindncscrub'} ne 'N')) {
		$apiMessage = "maindncscrub was invalid, must be Y or N";
	} elsif (! (defined($req->param->{'custdncscrub'}))) {
		$apiMessage = "custdncscrub was not defined";
	} elsif (($req->param->{'custdncscrub'} ne 'Y') &&
			 ($req->param->{'custdncscrub'} ne 'N')) {
		$apiMessage = "custdncscrub was invalid, must be Y or N";
	} elsif (! (defined($req->param->{'enablemobile'}))) {
		$apiMessage = "enablemobile was not defined";
	} elsif (($req->param->{'enablemobile'} ne 'Y') &&
			 ($req->param->{'enablemobile'} ne 'N')) {
		$apiMessage = "enablemobile was invalid, must be Y or N";
	}

	my $row;
	if (! defined($apiMessage)) { # passed validation so far ...
		my $row = $dbh->selectrow_hashref("select * from customer
			where CO_Number = $CO_Number");
		if ((! defined($row)) || (! defined($row->{'CO_Number'}))) {
			$apiMessage = "Authorization error";
		} else {
			$data->{'ContextCustomer'} = $row;
			$data->{'ContextReseller'} = $dbh->selectrow_hashref("select * from reseller
				where RS_Number = " . $data->{'ContextCustomer'}{'CO_ResNumber'});

			$row = $dbh->selectrow_hashref("select * from project
				where PJ_Number = $PJ_Number and PJ_CustNumber = $CO_Number");

			if ((! defined($row)) || (! defined($row->{'PJ_Number'}))) {
				$apiMessage = "Project authorization error";
			}
			$data->{'ContextProject'} = $row;
		}
		$data->{'PJ_Number'} = $PJ_Number;
		$data->{'CO_Number'} = $CO_Number;
	}

	if (! defined($apiMessage)) { # passed validation ...
		$data->{'ScrubMainDncInd'} = $req->param->{'maindncscrub'};
		$data->{'ScrubCustDncInd'} = $req->param->{'custdncscrub'};
		$data->{'ScrubMobilesInd'} = $req->param->{'enablemobile'};

		my $flist = upload($dbh, $req, $data);
		$apiMessage = "SUCCESS\nFiles:$flist\n";
	} else { # failed validation ...
		$apiMessage = "FAIL\n$apiMessage\n";
	}

	return $apiMessage;
}
	
sub handler {
	my $r = shift;

	mkdir('/tmp/LoadLeads') unless (-d '/tmp/LoadLeads');

	my $req = Apache2::Request->new($r, 
		POST_MAX => 20*1024*1024,
		DISABLE_UPLOADS => 0,
		TEMP_DIR => '/tmp/LoadLeads');

	my $dbh = DialerUtils::db_connect(); 
	my $data;
	my $method = $req->param->{'m'};

	if ((defined($method)) && ($method eq 'apiload')) {
		my $msg = apiload($req, $dbh, $r->method_number);

		$req->content_type('text/plain');
		print $msg;
		return Apache2::Const::OK;
	} else {
		$data = DialerUtils::step_one($req, $dbh,
			$req->param->{'CO_Number'}, 
			$req->param->{'PJ_Number'});
	}

	$data->{'ScrubMainDncInd'} = (defined($req->param->{'maindncscrub'})) ? 'Y' : 'N';
	$data->{'ScrubCustDncInd'} = (defined($req->param->{'custdncscrub'})) ? 'Y' : 'N';
	$data->{'ScrubMobilesInd'} = (defined($req->param->{'enablemobile'})) ? 'N' : 'Y';

	my $tname = 'LoadLeads.tt2';

	if ((defined($data->{'ErrStr'})) && (length($data->{'ErrStr'}) > 0)) {
		$data->{'ErrStr'} .= "\nAuthorization failed";
	} elsif ($data->{'Z_PJ_Permitted'} ne 'Yes') {
		$data->{'ErrStr'} .= " Not authorized. Try to login again";
	} else { 
		# logged in so ...
		# ... unwrap PJ_DisposDescrip
		if (defined($data->{'ContextProject'}{'PJ_DisposDescrip'})) {
			$data->{'X_Dispositions'} = JSON::from_json("[" . $data->{'ContextProject'}{'PJ_DisposDescrip'} . "]");
		}

		if (! defined($method)) {
			# drop through and show
		} elsif ($method eq 'load') {
			if ($r->method_number == Apache2::Const::M_POST) {
				$data->{'UploadFileList'} = upload($dbh, $req, $data);
			}
		} elsif ($method eq 'Delete') {
			$data->{'MenuMessage'} = delfile($req, $data, $dbh);
		} elsif ($method eq 'RedialLives') {
			$data->{'MenuMessage'} = redial_lives($req, $data, $dbh);
		} elsif ($method eq 'RedialMachines') {
			$data->{'MenuMessage'} = redial_machines($req, $data, $dbh);
		} elsif ($method eq 'RedialNonConn') {
			$data->{'MenuMessage'} = redial_nonconn($req, $data, $dbh);
		} elsif (substr($method,0,17) eq 'RedialDisposition') {
			my $disp = substr($method,17,44);
			$data->{'MenuMessage'} = redial_disp($req, $data, $dbh, $disp);
		} elsif ($method eq 'ReportCallResult') {
			$tname = report_callresults($req, $data, $dbh);
		} elsif ($method eq 'ReportTimezone') {
			$tname = report_timezone($req, $data, $dbh);
		} elsif ($method eq 'ReportDisposition') {
			$tname = report_disposition($req, $data, $dbh);
		} elsif ($method eq 'EditHeaders') {
			$tname = edit_headers($req, $data, $dbh);
		} elsif ($method eq 'Update') {
			if ($r->method_number == Apache2::Const::M_POST) {
				$data->{'MenuMessage'} = update_nfile($req, $data, $dbh);
			}
		} elsif ($method eq 'Download') {
			my $fn;
			my $zip;
			($data->{'MenuMessage'}, $zip, $fn) = download($req, $data, $dbh);

			if (! defined($data->{'MenuMessage'})) {
				# no errors 
				my $subreq = $r->lookup_file($zip);
				$subreq->content_type('application/zip');
				$req->headers_out->set('Content-disposition', "attachment; filename=\"DUMP-$fn.zip\"");
				return $subreq->run;
			}
		} elsif ($req->param->{'m'} eq 'show') {
			# do nothing before rendering the page
		} else {
			$data->{'ErrStr'} = 'm=' . $req->param->{'m'} . ' is not understood';
		}

		# ... dialfile table info
		my $projectnumbers = "projectnumbers_" . $data->{'PJ_Number'};
		my %tcoltot = (
			'NF_StartTotal' => 0,
			'NF_ScrubDuplicate' => 0,
			'LeadsLeft'	=> 0,
			'LeadsUsed'	=> 0,
			'LeadsUsedToday' => 0);

		# check that $tbl exists 
		my $res = $dbh->selectrow_hashref("show table status 
			where name = '$projectnumbers'");

		if ((defined($res)) && (defined($res->{'Name'}))) {
			if ($tname eq 'LoadLeads.tt2') {
				# totals
				my $tots = $dbh->selectall_arrayref("select count(*) as Count,
					PN_FileNumber, PN_Status, 
					IF(date(PN_CallDT) = current_date(),'Y','N') as Today
					from $projectnumbers group by PN_FileNumber, PN_Status, 
					IF(date(PN_CallDT) = current_date(),'Y','N')",
					{ Slice => {} });
				
				my %nftots;
				for my $tot (@$tots) {
					if ($tot->{'PN_Status'} eq 'X') {
						$nftots{$tot->{'PN_FileNumber'}}{'LeadsUsed'} +=
							$tot->{'Count'};

						if ($tot->{'Today'} eq 'Y') {
							$nftots{$tot->{'PN_FileNumber'}}{'LeadsUsedToday'} +=
								$tot->{'Count'};
						}
					} else {
						$nftots{$tot->{'PN_FileNumber'}}{'LeadsLeft'} +=
							$tot->{'Count'};
					}
				}

				my $sql = "select *	from numberfiles where NF_Project = " .
					$data->{'PJ_Number'} . ' order by NF_FileNumber desc'; 
				$res = $dbh->selectall_arrayref($sql, { Slice => {} });

				for my $rw (@$res) {
					for my $k ('LeadsLeft', 'LeadsUsed', 'LeadsUsedToday') {
						$rw->{$k} = $nftots{$rw->{'NF_FileNumber'}}{$k};
						$rw->{$k} = 0 if (! defined($rw->{$k}));
						$tcoltot{$k} += $rw->{$k};
					}

					$tcoltot{'NF_StartTotal'} += $rw->{'NF_StartTotal'};
					$tcoltot{'NF_ScrubDuplicate'} += $rw->{'NF_ScrubDuplicate'};
				}

				$data->{'trows'} = $res;
				$data->{'ttot'} = \%tcoltot;
			} else {
				$data->{'NFile'} = $dbh->selectrow_hashref("select *
					from numberfiles where NF_FileNumber = '" .
					$data->{'filenumber'} . "' limit 1");

				# ... unwrap NF_ColumnHeadings
				if (defined($data->{'NFile'}{'NF_ColumnHeadings'})) {
					$data->{'X_ColumnHeadings'} = JSON::from_json("[" . $data->{'NFile'}{'NF_ColumnHeadings'} . "]");
				}
			}
		}

		$dbh->disconnect;
	} # else

	# render the page
	$req->content_type('text/html');
	my $tt = Template->new(INCLUDE_PATH => '/dialer/www/perl')
		|| die $Template::ERROR, "\n";
	$tt->process($tname, $data) || die $tt->error(), "\n";

	return Apache2::Const::OK;
}
1;
