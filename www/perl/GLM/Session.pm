#!/usr/bin/perl

package GLM::Session;

use strict;
use warnings FATAL => 'all';
use JSON;
use IO::File;

# TODO clean up the /tmp/GLM-Session directory

sub _debug {

	return;

	print STDERR @_;
	print STDERR "\n";
}

sub _load_file {
	my $vars = shift;
	my $sid = shift;

	my $sessfile = "/tmp/GLM-Session/$sid";

	_debug("reading session info from: $sessfile");

	if (-e $sessfile) {
		my $jtxt = `cat $sessfile`;

		_debug("session file $sessfile contains: $jtxt");

		if ($jtxt && (length($jtxt) > 0)) {
			my $j = JSON::from_json($jtxt);

			_debug("session file $sessfile parsed as...");

			for my $k (sort keys %$j) {
				_debug("   $k = " . $j->{$k});
				$vars->{$k} = $j->{$k};
			}
		} else {
			_debug("session file $sessfile was empty");
			warn "Failed to get anything from session file";
		}
	} else {
		_debug("session file $sessfile did not exist");
	}
}

sub _make_id {

	my $rc = "";

	while (length($rc) < 48) {
		my $c = chr(48 + int(rand(76)));
		$rc .= $c if $c =~ /[0-9A-Za-z]/;
	}

	return $rc;
}

sub ApacheSession {
	# constructor from cookie
	my $class = shift;
	my $record = shift;
	my $request = shift;

	my $COOKIENAME = 'GLMSESSID';
	my $sid;

	_debug("Looking for cookie $COOKIENAME");
		
	if (defined($request->jar)) {
		$sid = $request->jar->get($COOKIENAME);
	}


	unless (($sid) && (length($sid) == 48) && 
		(-e "/tmp/GLM-Session/$sid")) {

		$sid = _make_id();
		_debug("made session id = $sid");
	} else {
		_debug("Existing $COOKIENAME: $sid");
	}


	my $s = {
		'SessionId' => $sid
	};
		

	# set a cookie
	my $cookie = Apache2::Cookie->new($record,
			 -name    =>  $COOKIENAME,
			 -value   =>  $sid,
			 -expires =>  '+10h'
			);
	$cookie->bake($record);

	_load_file($s, $sid);

	bless $s;
	return $s;
}

sub save {
	# saves the has
	my $self = shift;

	if ($self->{'_PURGED'}) {
		_debug("session is PURGED cannot save");
		return;
	}

	my $BASEDIR = '/tmp/GLM-Session';

	if (! -d $BASEDIR) {
		_debug("session dir $BASEDIR did not exist, creating it");
		mkdir $BASEDIR;
	}

	my $sessFH = new IO::File;
	if ($sessFH->open('>', "$BASEDIR/" . $self->{'SessionId'})) {
		_debug("saving these vars...");
		my $vars;
		for my $k (sort keys %$self) {
			$vars->{$k} = $self->{$k};
			_debug("  $k = " . $vars->{$k});
		}
		print $sessFH JSON::to_json($vars);
		undef $sessFH;
	} else {
		warn "Failed to save session: $!";
	}
}

sub DESTROY {
	my $self = shift;
	$self->save();
}

sub purge {
	my $self = shift;

	_debug("purging session: " . $self->{'SessionId'});
	
	unlink('/tmp/GLM-Session/' . $self->{'SessionId'});

	for my $k (keys %$self) {
		_debug("  purging session key: " . $k);
		delete $self->{$k};
	}

	$self->{'_PURGED'} = 1;
}

1;
