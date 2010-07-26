#!/usr/bin/perl

package AddCreditList;

use strict;
use warnings;

use Apache2::Const qw(:methods :common);

sub handler {
	my $r = shift;

	my $req = Apache2::Request->new($r, 
		POST_MAX => 10*1024,
		DISABLE_UPLOADS => 1);

	my $dbh = DialerUtils::db_connect();
	my $data = DialerUtils::step_one($req, $dbh);

	if ((defined($data->{'ErrStr'})) && (length($data->{'ErrStr'}) > 0)) {
		$data->{'ErrStr'} .= "\nAuthorization failed";
	} elsif ($data->{'Session'}{'L_Level'} < 5) {
		$data->{'ErrStr'} = "Need supervisor rights for this.";
	} else {
		my $clause;
		if ($data->{'Session'}{'L_Level'} == 6) {
			$clause = '(CO_ResNumber <= 1 or ac_ResNumber > 0)';
			if ((defined($data->{'ac_customer'})) && ($data->{'ac_customer'} > 0)) {
				$clause .= ' and ac_Customer = ' .  $data->{'ac_customer'};
			}
		} else {
			$clause = "CO_ResNumber = '" . $data->{'Session'}{'L_OnlyReseller'} . "' and ac_Customer = " .
				$data->{'ac_customer'};
		}

		$data->{'List'} = $dbh->selectall_arrayref(
			"select * from addcredit 
				left join customer on CO_Number = ac_customer 
				left join reseller on RS_Number = ac_ResNumber
			where $clause
			order by ac_datetime desc limit 1000", { Slice => {}});
	}
	$dbh->disconnect;

	# render the page
	$req->content_type('text/html');
	my $tt = Template->new(INCLUDE_PATH => '/dialer/www/perl')
		|| die $Template::ERROR, "\n";
	$tt->process('AddCreditList.tt2', $data) || die $tt->error(), "\n";

	return Apache2::Const::OK;
}
1;
