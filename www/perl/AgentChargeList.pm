#!/usr/bin/perl

package AgentChargeList;

use strict;
use warnings;

use Apache2::Const qw(:methods :common);

sub handler {
	my $r = shift;

	my $req = Apache2::Request->new($r, 
		POST_MAX => 10*1024,
		DISABLE_UPLOADS => 1);

	my $dbh = DialerUtils::db_connect(); 
	my $data = DialerUtils::step_one($req,$dbh);

	my $OnlyRes = $data->{'Session'}{'L_OnlyReseller'};

	if ((defined($data->{'ErrStr'})) && (length($data->{'ErrStr'}) > 0)) {
		$data->{'ErrStr'} .= "\nAuthorization failed";
	} elsif ($data->{'Session'}{'L_Level'} < 5) {
		$data->{'ErrStr'} = "Need supervisor rights for this.";
	} else {
		my $level = $data->{'Session'}{'L_Level'};
		# which resellers?
		my $where = '';
		if ($level == 5) {
			$where = "where RS_Number = '$OnlyRes'";
		}

		$data->{'X_ResellerList'} = $dbh->selectall_arrayref(
			"select * from reseller $where", { Slice => {}});

		# which reseller used in the sql
		$where = "";
		if ((defined($data->{'RS_Number'})) &&
				($data->{'RS_Number'} > 0)) {
			$where = " and CO_ResNumber = " . $data->{'RS_Number'};
		} else {
			if ($level == 5) {
				$where = " and CO_ResNumber = '$OnlyRes'";
				$data->{'RS_Number'} = $OnlyRes;
			} else {
				$data->{'RS_Number'} = 0;
			}
		}

		# any particular customer by Number?
		if ((defined($data->{'CO_Number'})) && 
				($data->{'CO_Number'} > 0)) {
			$where .= " and CO_Number = '" . 
				$data->{'CO_Number'} . "'";
		} else {
			$data->{'CO_Number'} = 0;
		}

		# by name prefix?
		if ((defined($data->{'CO_Name'})) && 
				(length($data->{'CO_Name'}) > 0)) {
			$where .= q( and CO_Name like ') . 
				$data->{'CO_Name'} . "%'";
		}

		$data->{'X_Sql'} = "select * from agentcharge, customer
			where AC_Customer = CO_Number$where order by AC_DateTime desc limit 200";
		my $res = $dbh->selectall_arrayref($data->{'X_Sql'}, { Slice => {} });
		$data->{'List'} = $res;
	}
	$dbh->disconnect;

	# render the page
	$req->content_type('text/html');
	my $tt = Template->new(INCLUDE_PATH => '/dialer/www/perl')
		|| die $Template::ERROR, "\n";
	$tt->process('AgentChargeList.tt2', $data) || die $tt->error(), "\n";

	return Apache2::Const::OK;
}
1;
