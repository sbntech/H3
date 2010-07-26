#!/usr/bin/perl

use strict;
use warnings;
use JSON;
use lib '/home/grant/sbn-git/www/perl/';
use DialerUtils;

my $PJ_Number	= $ARGV[0];
my $path		= $ARGV[1];
my $mainscrub	= $ARGV[2];
my $custscrub	= $ARGV[3];
my $mobiles		= $ARGV[4];

$mainscrub = 'Y' unless $mainscrub eq 'N';
$custscrub = 'Y' unless $custscrub eq 'N';
$mobiles   = 'Y' unless $mobiles eq 'N';

my $data = {
				'PJ_Number' => $PJ_Number,
				'ScrubMainDncInd' => $mainscrub,
				'ScrubCustDncInd' => $custscrub,
				'ScrubMobilesInd' => $mobiles,
			};

my $dbh = DialerUtils::db_connect(); 
$data->{'ContextProject'} = $dbh->selectrow_hashref(
	"select * from project where PJ_Number = $PJ_Number");

die "bad project id $PJ_Number" unless $data->{'ContextProject'}{'PJ_Number'} == $PJ_Number;

$data->{'ContextCustomer'} = $dbh->selectrow_hashref(
	"select * from customer where CO_Number = " . $data->{'ContextProject'}{'PJ_CustNumber'});

my $base = $path;
$base =~ s/.*(\\|\/)(.*)/$2/;

my $JobId = rand();
$data->{'NF_FileName'} = $base;
$data->{'NF_FileName'} =~ tr/'"//d;
system("cp $path /dialer/projects/workqueue/LoadLeads-DATA-$JobId");
open JFILE, '>', "/tmp/LoadLeads-JSON-$JobId" or die "opening failed: $!";
print JFILE JSON::to_json($data);
close JFILE;
system("mv /tmp/LoadLeads-JSON-$JobId /dialer/projects/workqueue/");

$dbh->disconnect;
