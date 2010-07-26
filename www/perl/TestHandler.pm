#!/usr/bin/perl

package TestHandler;

use strict;
use warnings;

use Apache2::Const qw(:methods :common);

sub handler {
	my $record = shift;

	my $request = Apache2::Request->new($record, 
		POST_MAX => 10*1024,
		DISABLE_UPLOADS => 1);

	my $session = GLM::Session->ApacheSession($record, $request);
	$session->{'L_Level'} = 0;
	$session->{'L_Name'} = 'fred';
	$session->save; # not strictly necessary
	#$session->purge;

	# render the page
	$request->content_type('text/html');
	print "<html><head></head><body><pre>";
	for my $k (keys %$session) {
		print "$k --> " . $session->{$k} . "\n";
	}

	print "</pre></body></html>";
	return Apache2::Const::OK;

}
1;
