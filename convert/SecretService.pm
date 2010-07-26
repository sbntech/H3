#!/usr/bin/perl

package SecretService;

use strict;
use warnings;
use Net::Server;
use Digest::SHA qw(sha512_base64);
use base qw(Net::Server::PreFork);

my $hp = '1u4VXuf1u+QLeoaOQxfBr5Fv1wTzB+NT3F9t4Xy8pj91u7GN6+ivwdgflg8ip5JuHbGc+YN04Y4bX6W+Vhp7eA';
my $secret = <STDIN>;
chomp($secret);

my $h = sha512_base64($secret);

if ($h ne $hp) {
	print "Incorrect parameter\n";
	exit;
}

SecretService->run({
	host => '127.0.0.1', 
	port => 8230, 
	background => 0,
	setsid => 1,
	log_file => '/var/log/SecretService.log',
	pid_file => '/var/run/SecretService.pid',
	cidr_allow => '127.0.0.1/32'
});

sub process_request {
	my $self = shift;

	print "#>>$secret<<#";
}

1;
