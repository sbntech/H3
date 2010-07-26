#!/usr/bin/perl

package ResellerList;

use strict;
use warnings;

use Apache2::Const qw(:methods :common);

sub handler {
	my $r = shift;

	my $req = Apache2::Request->new($r, 
		POST_MAX => 10*1024,
		DISABLE_UPLOADS => 1);

	my $dbh = DialerUtils::db_connect(); 
	my $data = DialerUtils::step_one($req, $dbh, 0, 0);

	if ((defined($data->{'ErrStr'})) && (length($data->{'ErrStr'}) > 0)) {
		$data->{'ErrStr'} .= "\nAuthorization failed";
	} elsif ($data->{'Session'}{'L_Level'} != 6) {
		$data->{'ErrStr'} .= " Not authorized!";
	} else {
		$data->{'List'} = $dbh->selectall_arrayref(
			"select * from reseller order by RS_DistribCode, RS_Name", { Slice => {}});
	}
	$dbh->disconnect;

	# render the page
	$req->content_type('text/html');
	my $tt = Template->new(INCLUDE_PATH => '/dialer/www/perl')
		|| die $Template::ERROR, "\n";
	$tt->process('ResellerList.tt2', $data) || die $tt->error(), "\n";

	return Apache2::Const::OK;
}
1;
