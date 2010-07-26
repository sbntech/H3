#!/usr/bin/perl

package ProjectList;

use strict;
use warnings;
use DateTime;

use Apache2::Const qw(:methods :common);

sub TZ_now {
	# 0=Eastern ... 3=Pacific
	my $TZOffset = shift;
	my $tz;
	my $tzstr;

	if ($TZOffset == 0) {
		$tz = 'America/New_York';
		$tzstr = 'Eastern';
	} elsif ($TZOffset == 1) {
		$tz = 'America/Chicago';
		$tzstr = 'Central';
	} elsif ($TZOffset == 2) {
		$tz = 'America/Denver';
		$tzstr = 'Mountain';
	} elsif ($TZOffset == 3) {
		$tz = 'America/Los_Angeles';
		$tzstr = 'Pacific';
	} else {
		# default
		$tz = 'America/New_York';
		$tzstr = 'Eastern';
	}
		
	my $dt = DateTime->now(time_zone => $tz);

	return $dt->strftime('%I:%M %p') . " $tzstr";
}

sub handler {
	my $r = shift;

	my $req = Apache2::Request->new($r, 
		POST_MAX => 10*1024,
		DISABLE_UPLOADS => 1);

	my $dbh = DialerUtils::db_connect(); 
	my $data = DialerUtils::step_one($req, $dbh,
		$req->param->{'CO_Number'}, 0);


	if ($data->{'Z_CO_Permitted'} ne 'Yes') {
		$data->{'ErrStr'} .= " Not authorized. Try to login again";
	} else {
		
		$data->{'CustNowTime'} = TZ_now(abs($data->{'ContextCustomer'}{'CO_Timezone'}));

		my $user = $data->{'Session'}{'L_Number'};
		my $level = $data->{'Session'}{'L_Level'};
		my $clause1 = '';
		if (($user > 0) && ($level == 1)) {
			$clause1 = " and PJ_User = $user ";
		}

		my $clause2 = '';
		if ((defined($data->{'ActiveOnly'})) &&
			($data->{'ActiveOnly'} eq 'Yes')) {
			$clause2 = " and PJ_DateStart <= current_date() and PJ_DateStop >= current_date() ";
		}

		my %typeLookup = (
			'C' => 'Cold Calling',
			'P' => 'Press 1',
			'S' => 'Survey',
			'A' => 'Message Delivery' );

		$data->{'ProjectList'} = $dbh->selectall_arrayref(
			"select * from project where PJ_CustNumber = " .
			$data->{'CO_Number'} . $clause1 . $clause2 .
			" and PJ_Visible = 1 order by PJ_Number desc",
			{ Slice => {}});

		for my $p (@{$data->{'ProjectList'}}) {
			$p->{'PJ_WorkdayStart'} = DialerUtils::buildTime($p->{'PJ_TimeStart'}, $p->{'PJ_TimeStartMin'});
			$p->{'PJ_WorkdayStop'} = DialerUtils::buildTime($p->{'PJ_TimeStop'}, $p->{'PJ_TimeStopMin'});	
			$p->{'PJ_ProspectStart'} = DialerUtils::buildTime($p->{'PJ_Local_Time_Start'}, $p->{'PJ_Local_Start_Min'});
			$p->{'PJ_ProspectStop'} = DialerUtils::buildTime($p->{'PJ_Local_Time_Stop'}, $p->{'PJ_Local_Stop_Min'});

			$p->{'PJ_TypeStr'} = $typeLookup{$p->{'PJ_Type'}};

			$p->{'ReportSummary'} = $dbh->selectrow_hashref(
				"select sum(RE_Calls) as Calls, round(sum(RE_Tot_cost),2) as Cost, 
				round(sum(RE_Tot_Sec) / 60, 0) as Minutes 
				from report where RE_Date = current_date() and RE_Project = " . $p->{'PJ_Number'});

			# count leads
			$p->{'LeadsLeft'} = {'Total' => 0, '0' => 0, '1' => 0, '2' => 0, '3' => 0, 'Other' => 0 };
			my $projectnumbers = 'projectnumbers_' . $p->{'PJ_Number'};
			my $pes = $dbh->selectrow_hashref("show table status 
				where name = '$projectnumbers'");

			if ((defined($pes)) && (defined($pes->{'Name'}))) {
				# totals
				my $tots = $dbh->selectall_arrayref("select count(*) as Count,
					PN_Timezone from $projectnumbers
					where PN_Status != 'X'
					group by PN_Timezone",
					{ Slice => {} });
				
				for my $tot (@$tots) {
					$p->{'LeadsLeft'}{'Total'} += $tot->{'Count'};

					if ($tot->{'PN_Timezone'} > 3) {
						$p->{'LeadsLeft'}{'Other'} += $tot->{'Count'};
					} else {
						$p->{'LeadsLeft'}{$tot->{'PN_Timezone'}}
							+= $tot->{'Count'};
					}
				}
			} # count leads
		} # for
	}
	$dbh->disconnect;

	# render the page
	$req->content_type('text/html');
	my $tt = Template->new(INCLUDE_PATH => '/dialer/www/perl')
		|| die $Template::ERROR, "\n";
	$tt->process('ProjectList.tt2', $data) || die $tt->error(), "\n";

	return Apache2::Const::OK;
}
1;
