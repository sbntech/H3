#!/usr/bin/perl

package PopupCustom;

use strict;
use warnings;
use Apache2::Const qw(:methods :common);

sub lvva {
	# lvva is the customer's name
	my $dbh = shift;
	my $data = shift;

	# fields: CalledNumber, LeadCode, AG_Project
	my $d = $dbh->selectrow_hashref("select * from project
		where PJ_Number = '" .  $data->{'AG_Project'} . "'");

	if (defined($data->{'LeadCode'})) {
		if ($data->{'LeadCode'} eq '2') {
			DialerUtils::custdnc_add($d->{'PJ_CustNumber'},
				[ $data->{'CalledNumber'} ]);
		}

		# write coding to the popup logfile
		my $dt = DateTime->now(); $dt->set_time_zone('America/New_York');
		my $fname = '/dialer/projects/_' . $data->{'AG_Project'} .
			'/voiceprompts/popup-results-' . $dt->ymd . '.csv';

		my $LVVALOG;
		if (open($LVVALOG, '>>', $fname)) {
			use Fcntl ':flock';
			flock($LVVALOG, LOCK_EX);
			print $LVVALOG $data->{'CalledNumber'} . ',' . $data->{'LeadCode'} . "\n";
			flock($LVVALOG, LOCK_UN);
			close $LVVALOG;
		} else {
			warn "failed to open $fname";
		}
	}
}

sub handler {
	my $r = shift;

	my $req = Apache2::Request->new($r, 
		POST_MAX => 10*1024,
		DISABLE_UPLOADS => 1);

	my $template;
	my %data;
	DialerUtils::formdata($req, \%data);
	my $dbh = DialerUtils::db_connect();

	if (defined($data{'dispatch'})) {
		if ($data{'dispatch'} eq 'lvva') {
			lvva($dbh, \%data)
		} else {
			warn "Unhandled dispatch code: " . $data{'dispatch'};
		}
	}

	$dbh->disconnect;

	my $location = '/pg/Agent?method=poll';
	$r->headers_out->add('Location' => $location);
	return Apache2::Const::REDIRECT;
}
1;
