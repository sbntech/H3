#!/usr/bin/perl

use strict;
use warnings;

use lib qw(/home/grant/H3/convert /ZM/people/grant/H3/convert);
use Messenger;

$|++; #unbuffered output to stdout

sub receiver {

	my $mq = Messenger::end_point();

	print "Use Ctrl-C to quit\n";

	while (1) {
		
		sleep(1);

		my $messages = $mq->pop_messages;

		for my $msg (@$messages) {
			print "[$msg]\n";
		}
	}
}


sub sender {

	my $mq = Messenger::end_point($ARGV[0]);

	print "Use Ctrl-C to quit\n";

	while (1) {
		print "Enter a message: ";
		my $inp = <STDIN>;
		chomp $inp;

		for my $msg (split(/\//, $inp)) {
			$mq->send_msg($msg);
			print "Sent " . length($msg) . " chars: [$msg]\n";
		}
	}
}


if (defined($ARGV[0])) {
	sender();
} else {
	receiver();
}
