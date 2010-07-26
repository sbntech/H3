#!/usr/bin/perl

# takes the recordings and recodes them and sends them to the apache server

use strict;
use warnings;
use lib '/home/grant/sbn-git/convert';
use lib '/home/grant/sbn-git/www/perl';
use DialerUtils;
use Logger;

my $monitorDIR = '/var/spool/asterisk/monitor';
my $running = 1;
my %recs;

die "FATAL: asterisk monitor directory ($monitorDIR) missing" unless (-d $monitorDIR);
my $worker0 = '10.9.2.1'; 
my $me = DialerUtils::who_am_I();
$worker0 = 'localhost' if $me eq 'swift'; 

DialerUtils::daemonize();

my $log = Logger->new('/var/log/astrecordings.log');

sub exit_handler {
	$log->info("signal caught: STOPPING");
	$running = 0;
}

sub process_recordings {

	opendir(my $dh, $monitorDIR) || die "failed to open $monitorDIR";
	my $count = 0;

	while(my $ent = readdir($dh)) {
		my ($tel, $pj) = ($ent =~ /CC-(\d{10})-pjq(\d{1,7}).ulaw/);
		next unless defined($tel);

		my ($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size,$atime,$mtime,$ctime,$blksize,$blocks) = stat("$monitorDIR/$ent");
		next unless $size > 0;

		if ((!defined($recs{$ent})) || ($recs{$ent}->{Size} != $size)) {
			$recs{$ent} = { Size => $size, When => time() };
		}

		my $age = time() - $recs{$ent}->{When};

		if ($age < 60 * 3) {
			# file must be same size for 3 minutes (since they might still be writing)
			# $log->debug("$ent skipped (size=$size)");
			next;
		}

		delete $recs{$ent};
		my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($mtime);
		my $stamp = sprintf("%d%02d%02d_%02d%02d%02d", 1900 + $year, $mon + 1, $mday, $hour, $min, $sec);
		my $tfile = "/tmp/$stamp-$tel.wav";

		system("sox -t ul -r 8000 -c 1 $monitorDIR/$ent $tfile");
		unlink("$monitorDIR/$ent");

		if ($worker0 eq 'localhost') {
			system("mv $tfile /dialer/projects/_$pj/recordings/");
		} else {
			system("scp -q -P 8946 $tfile $worker0:/dialer/projects/_$pj/recordings/");
			unlink($tfile);
		}

		$count++;
		$log->debug("$ent sent to project $pj as $stamp-$tel.wav");
	}

	closedir $dh;

	if ($count > 0) {
		$log->info("$count recordings sent");
	}

}

# ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++ main

$SIG{INT} = \&exit_handler;
$SIG{QUIT} = \&exit_handler;
$SIG{TERM} = \&exit_handler;

$log->debug("Starting (me=$me, $worker0)");

while ($running == 1) {

	process_recordings();
	sleep 60;

}

$log->debug("Terminating");
$log->fin;

exit;
