#!/usr/bin/perl

package ProjectReport;

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

	my $template = 'ProjectReport.tt2';

	if ((defined($data->{'ErrStr'})) && (length($data->{'ErrStr'}) > 0)) {
		$data->{'ErrStr'} .= "\nAuthorization failed";
	} elsif ($data->{'Z_PJ_Permitted'} ne 'Yes') {
		$data->{'ErrStr'} .= " Not authorized. Try to login again";
	} else { 
		# logged in so ...
		if ($r->method_number == Apache2::Const::M_POST) {
			$template = 'ProjectReportText.tt2';
			my $dateClause = '';
			if ($data->{'TextReportDate'} =~ /\d{4}-\d{2}-\d{2}/) {
				$data->{'Prospect'} = $dbh->selectrow_hashref(
					"select * from report where RE_Project = '" . 
					$data->{'PJ_Number'} . "' and RE_Date = '" .
					$data->{'TextReportDate'} . "' and RE_Agent = 9999");

				$data->{'Prospect'}->{'Transfers'} = 0;
				$data->{'Prospect'}->{'LostTransfers'} = 0;
				$data->{'Summary'}->{'TotalCalls'} = $data->{'Prospect'}->{'RE_Calls'};
				$data->{'Summary'}->{'TotalSeconds'} = $data->{'Prospect'}->{'RE_Tot_Sec'};

				$data->{'AgentList'} = $dbh->selectall_arrayref(
					"select * from report " .
					"left join agent on RE_Agent = AG_Number " .
					"where RE_Project = '" .  $data->{'PJ_Number'} .
					"' and RE_Date = '" . $data->{'TextReportDate'} .
					"' and RE_Agent != 9999",
					{ Slice => {}});

				for my $ag (@{$data->{'AgentList'}}) {
					$ag->{'AG_Name'} = 'Call Center' if $ag->{'RE_Agent'} == 1111;
					$data->{'Prospect'}->{'Transfers'} += $ag->{'RE_Connectedagent'};
					$data->{'Prospect'}->{'LostTransfers'} += ($ag->{'RE_Agentnoanswer'} + $ag->{'RE_Agentbusy'} + $ag->{'RE_Hungupb4connect'});
					$data->{'Summary'}->{'TotalCalls'} += $ag->{'RE_Calls'};
					$data->{'Summary'}->{'TotalSeconds'} += $ag->{'RE_Tot_Sec'};
				}

			} else {
				$data->{'ErrStr'} = "Invalid parameters provided, try again";
			}
		} else {
			$data->{'List'} = $dbh->selectall_arrayref(
				"select * from report 
				left join agent on AG_Number = RE_Agent
				where RE_Project = '" . 
				$data->{'PJ_Number'} . "' order by re_date desc, re_agent desc limit 400",
				{ Slice => {}});
			$data->{'DistinctDateList'} = $dbh->selectall_arrayref(
				"select distinct RE_Date from report where RE_Project = '" . 
				$data->{'PJ_Number'} . "'order by RE_Date desc", { Slice => {}});
		}
	}
	$dbh->disconnect;

	# render the page
	$req->content_type('text/html');
	my $tt = Template->new(INCLUDE_PATH => '/dialer/www/fancy:/dialer/www/perl', RELATIVE => 1,)
		|| die $Template::ERROR, "\n";
	$tt->process($template, $data) || die $tt->error(), "\n";

	return Apache2::Const::OK;
}
1;
