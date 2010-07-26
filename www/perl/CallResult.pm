#!/usr/bin/perl

package CallResult;
# used by nvrs for billing and reporting cdrs

use strict;
use warnings;
use Apache2::Const qw(:methods :common);
use File::Temp qw( tempfile );

sub handler {
	my $r = shift;
	my $POSTMAX = 1024*1024*40;

	my $req = Apache2::Request->new($r, 
		POST_MAX => $POSTMAX,
		DISABLE_UPLOADS => 1);

	if ($r->method_number == Apache2::Const::M_POST) {

		my $dat;
		$r->read($dat, $POSTMAX);

		# write the body to a temporary file and move it onto the queue
		my ($fh, $filename) = tempfile();
		if (! defined($fh)) {
			warn "ERROR! failed to create a temporary file for call results";
			return Apache2::Const::NOT_FOUND;
		}

		print $fh $dat;
		close $fh;

		system("mv $filename /dialer/call-results-queue");
	}

	return Apache2::Const::OK;
}
1;
