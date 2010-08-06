#!/usr/bin/perl 

# each nvr generates files /dialer/projects/_999/cdr/cdr-YYYY-MM-DD-10.80.2.*.txt
# this script concatenates cdr files into 1 file for each date (before today)
# and zips them up

# it is expected to run as a nightly cron job

use strict;
use warnings;
use DateTime;

# create @cdrfiles the list of cdr files that need merging and zipping
my $dt = DateTime->now;
$dt->set_time_zone('America/New_York');
my $today = sprintf("%04d-%02d-%02d", $dt->year, $dt->month, $dt->day);
my @cdrfiles = grep(!/cdr-$today/, `find /dialer/projects -type f -wholename "*/cdr/cdr-20*.txt"`);

# build the to-do list
my %todo;
for my $f (@cdrfiles) {
	if ($f =~ /.dialer.projects._(\d*)\/cdr\/cdr-(\d{4}-\d{2}-\d{2}).*\.txt/) {
		$todo{$2}{$1} = 1; # {date}{project}
	} else {
		warn("skipping $f because it has a bad name-pattern for a cdr file");
	}
}

# cat and zip the to-do list
for my $d (keys %todo) {
	for my $p (keys %{$todo{$d}}) {
		system("cat /dialer/projects/_$p/cdr/cdr-$d*.txt > /tmp/cdr-$d.txt");
		system("zip -q -j /dialer/projects/_$p/cdr/cdr-$d.zip /tmp/cdr-$d.txt");
		system("rm /dialer/projects/_$p/cdr/cdr-$d*.txt");
	}
}


# ---- handle recordings ----
$today = sprintf("%04d%02d%02d", $dt->year, $dt->month, $dt->day);
my @recfiles = grep(!/$today/, `find /dialer/projects -type f -wholename "*/recordings/20*.wav"`);

# build the to-do list
%todo = ();
for my $f (@recfiles) {
	if ($f =~ /.dialer.projects._(\d*)\/recordings\/(\d{4}\d{2}\d{2}).*\.wav/) {
		$todo{$2}{$1} = 1; # {date}{project}
	} else {
		warn("skipping $f because it has a bad name-pattern for a rec file");
	}
}

# cat and zip the to-do list
for my $d (keys %todo) {
	for my $p (keys %{$todo{$d}}) {
		system("zip -q -j -m -T /dialer/projects/_$p/recordings/rec-$d.zip /dialer/projects/_$p/recordings/$d*.wav");
	}
}

system("find /dialer/projects -type f -wholename \"*/recordings/rec-20*.zip\" -mtime +30 -delete");

