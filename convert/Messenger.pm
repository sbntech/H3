#!/usr/bin/perl

package Messenger;

use strict;
use warnings;

=pod
Sends and receives little messages
=cut

use IO::Socket::INET;
use JSON;

sub end_point {
	# constructor
	my $Out_IP = shift;

	my $obj = {
		'_inbuffer' => ''
	};

	if (defined($Out_IP)) {
		$obj->{'OutSock'} = IO::Socket::INET->new(
				PeerAddr => $Out_IP,
				PeerPort => 1666,
				Proto => 'udp',
				Blocking => 0);

		die "cannot create client socket: $!" unless defined($obj->{'OutSock'});
	} else {
		$obj->{'InSock'} = IO::Socket::INET->new(
					LocalAddr => '0.0.0.0',
					LocalPort => 1666,
					Proto => 'udp',
					ReuseAddr => 1,
					Blocking => 0);
		die "cannot create server socket: $!" unless defined($obj->{'InSock'});
	}

	return bless $obj;
}


sub send_msg {
	my $self = shift;
	my $msg = shift;

	$self->{'OutSock'}->send(sprintf("%c%d:%s%c", 2, length($msg), $msg, 3));

}

sub pop_messages {
	my $self = shift;

	my $messages = [];

	my $tbuf;
	while (1) {
		$self->{'InSock'}->recv($tbuf, 1024 * 100, 0);

		if (!defined($tbuf)) {
			last;
		}

		if (length($tbuf) == 0) {
			last;
		}

		$self->{'_inbuffer'} .= $tbuf;
	}

	MESSAGE: while (length($self->{'_inbuffer'}) > 0) {
		# parse out messages
		my $mstart = index($self->{'_inbuffer'}, chr(2));
		if ($mstart == 0) {
			# message start token is where we expect it
			my $mcolon = index($self->{'_inbuffer'}, ':');
			last MESSAGE unless ($mcolon > 0);
			
			if ($self->{'_inbuffer'} =~ /^\02(\d*):/) {
				my $mlength = $1;
				my $charsNeeded = $mcolon + $mlength + 2;

				last MESSAGE if length($self->{'_inbuffer'}) < $charsNeeded;

				my $mend = index($self->{'_inbuffer'}, chr(3), $charsNeeded - 1);

				my $alen = $mend - $mcolon - 1;
				if ($alen != $mlength) {
					warn "bad length (=$mlength) provided, actual length is $alen"
				}

				my $msg = substr($self->{'_inbuffer'}, $mcolon + 1, $alen);
				$self->{'_inbuffer'} = substr($self->{'_inbuffer'}, $mend + 1);
				push @$messages, $msg;

			} else {
				my $rubbish = substr($self->{'_inbuffer'}, 0, $mcolon);
				$self->{'_inbuffer'} = substr($self->{'_inbuffer'}, $mcolon + 1);
				warn "bad format, no message length, shifted [$rubbish]";
			}
		} elsif ($mstart < 0) {
			# no message start token
			warn "apparent data corruption, ignoring ["
				. $self->{'_inbuffer'} . "]";
			$self->{'_inbuffer'} = '';
		} elsif ($mstart > 0) {
			# message start token is preceeded by rubbish
			my $rubbish = substr($self->{'_inbuffer'}, 0, $mstart);
			$self->{'_inbuffer'} = substr($self->{'_inbuffer'}, $mstart + 1);
			warn "apparent data corruption, junking [$rubbish]";
		}
	} # MESSAGE

	return $messages;
}











1;
