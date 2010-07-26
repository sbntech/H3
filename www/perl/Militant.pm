#!/usr/bin/perl

package Militant;

use strict;
use warnings;

use Apache2::Const qw(:methods :common);

sub handler {
	my $r = shift;

	my $req = Apache2::Request->new($r, 
		POST_MAX => 2*1024*1024,
		DISABLE_UPLOADS => 1);

	my $dbh = DialerUtils::db_connect(); 
	my $data = DialerUtils::step_one($req, $dbh, 0, 0);

	if ((defined($data->{'ErrStr'})) && (length($data->{'ErrStr'}) > 0)) {
		$data->{'ErrStr'} .= "\nAuthorization failed";
	} elsif ($data->{'Session'}{'L_Level'} != 6) {
		$data->{'ErrStr'} .= " Not authorized!";
	} else {
		# logged in so ...
		if ($r->method_number == Apache2::Const::M_POST) {
			my $sbn2 = DialerUtils::sbn2_connect(); 

			my $inlist = $data->{'MilitantPhone'};
			my $newPh = '';
			my $oldPh = '';
			my $errPh = '';

			while (length($inlist) > 0) {
				my $len = index($inlist, "\n");
				my $mphone;
				if ($len > 0) {
					$mphone = substr($inlist, 0, $len);
					$inlist = substr($inlist, $len + 1);
				} else {
					$mphone = $inlist;
					$inlist = '';
				}

				$mphone =~ tr/0-9//cd; # normalize

				if ($mphone =~ /\d{10}/) {
					my $get = $sbn2->selectrow_hashref("select * from
						dncmilitant where PhNumber = $mphone");

					if ((defined($get->{'PhNumber'})) &&
						($get->{'PhNumber'} == $mphone)) {
						$oldPh .= "$mphone was already there<br>";
					} else {
						my $aff = $sbn2->do("insert into dncmilitant
							values ($mphone)");
						if ($aff > 0) {
							$newPh .= "$mphone was added<br>";
						} else {
							$errPh .= "$mphone had an error<br>";
						}
					}
				}
			}
			
			$data->{'MessageStr'} = '';
			$data->{'MessageStr'} .= $newPh if length($newPh) > 0;
			$data->{'MessageStr'} .= $oldPh if length($oldPh) > 0;
			$data->{'MessageStr'} .= $errPh if length($errPh) > 0;

			$sbn2->disconnect;
		}
	}
	$dbh->disconnect;

	# render the page
	$req->content_type('text/html');
	my $tt = Template->new(INCLUDE_PATH => '/dialer/www/perl')
		|| die $Template::ERROR, "\n";
	$tt->process('Militant.tt2', $data) || die $tt->error(), "\n";

	return Apache2::Const::OK;
}
1;
