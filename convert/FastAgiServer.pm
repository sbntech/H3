#!/usr/bin/perl

package FastAgiServer;

use strict;
use warnings;
use Net::Server;
use base qw(Net::Server::PreFork);

use Asterisk::AGI;
use DBI;
use DateTime;

use lib qw(/dialer/www/perl);
use DialerUtils;

my $worker0 = '10.9.2.1';
my $hostname = `hostname`;
chomp($hostname);
if ($hostname eq 'swift') {
	$worker0 = '10.10.10.6';
}

FastAgiServer->run({
	host => $worker0, 
	port => 4573, 
	background => 1,
	setsid => 1,
	log_file => '/var/log/FastAgiServer.log',
	pid_file => '/var/run/FastAgiServer.pid',
	user => 'root',
	group => 'root',
	cidr_allow => '10.0.0.0/8'
});

sub flog {
	my ($dt, $tm) = DialerUtils::local_datetime();
	print STDERR "$dt $tm ";
	print STDERR @_;
	print STDERR "\n";
}

sub process_request {
	my $self = shift;

   my %CUSTLOOKUP = (
		   '18663909947' => 12424, # stealth
		   '18667148087' => 13154, # a-media
		   '18662786488' => 11966, # cleartalk
		   '18667148086' => 11966, # cleartalk
		   '18667148094' => 12480, # Ivan
		   '18669350848' => 13086, # Skyline
		   '18669350850' => 13088, # L & N
	);

	my $dbh = DialerUtils::db_connect();

	my $AGI = new Asterisk::AGI;
	my %input = $AGI->ReadParse();
#print STDERR '%input:' . "\n";
#for my $i (keys %input) {
#	print STDERR "$i = " . $input{$i} . "\n";
#}

	if ($input{'network_script'} eq 'RemoveCustDNC') {
		my $num = $AGI->get_variable("DNCNumber");
		my $ext = $AGI->get_variable("DNCExten");

		if ($num !~ /^\d{10}$/) {
			flog("RemoveCustDNC: [$num] does not look like a phone number [origin: $ext]");
			return;
		}
		my $custno = $CUSTLOOKUP{$ext};

		unless (defined($custno)) {
			my $ccid = $dbh->selectrow_hashref("select CC_Customer from custcallerid
				where CC_CallerId = '$ext' limit 1");

			$custno = $ccid->{'CC_Customer'};
		}

		unless ((defined($custno)) && ($custno > 0)) {
			flog("RemoveCustDNC: could not find customer from [$ext] ($num called)");
			$custno = 0;
		}

		my $r = DialerUtils::custdnc_add($custno, [ $num ]);
		flog("RemoveCustDNC: $custno:$num added (rows inserted: $r) [origin: $ext]");

	} elsif ($input{'network_script'} eq 'GetAvailableAgent') {
		my $proj = $AGI->get_variable("PJ_Number");
		my $prospectPhone = $AGI->get_variable("ProspectNumber");
		my $ag = DialerUtils::connect_agent($dbh, $proj, $prospectPhone);
		flog("GetAvailableAgent: for project $proj and prospect $prospectPhone ===> " 
			. $ag->{'AgentId'} . " at " . $ag->{'AgentPhoneNumber'});
		$AGI->set_variable('AgentNumber', $ag->{'AgentPhoneNumber'});
		$AGI->set_variable('AgentId', $ag->{'AgentId'});
	}
}

1;
