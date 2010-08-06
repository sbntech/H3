#!/usr/bin/perl

# needs to run 
	# after the backup on db completes
	# after the cdrs are compressed

use strict;
use warnings;

my @now = localtime(time);
my $wday = $now[6];
my $weekday = ('Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday')[$wday];

my $bu = "/backup";
die "No backup directory $bu found" unless (-d $bu);

# make a local copy of the data

# (Note: db creates a dump and rsyncs it to $bu/mysql-data);
system("rsync -a --delete 10.80.2.32:/root/mysql/dialer/ $bu/mysql-data/dialer"); # dailer db
system("rsync -a --delete 10.80.2.32:/root/mysql/sbn2/ $bu/mysql-data/sbn2"); # sbn2 db
system("rsync  --exclude 'projects/workqueue' --exclude 'recordings' --exclude 'projects/log' --delete-before --delete-excluded -a /dialer/projects/ $bu/projects"); # projects

# make offsite copy of the data
system("rsync -a --delete-before -e 'ssh -p 22' $bu/ root\@24.234.118.147:/quickdials-backup");
