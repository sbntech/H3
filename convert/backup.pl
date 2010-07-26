#!/usr/bin/perl

use strict;
use warnings;

my @now = localtime(time);
my $wday = $now[6];
my $weekday = ('Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday')[$wday];

my $bu = "/extra-b/sbndials-backup";
die "No backup directory $bu found" unless (-d $bu);

# make a local copy of the data
# (Note: db1 creates a dump and rsyncs it to $bu/mysql-data);
system("rsync -a --delete 10.9.2.16:/root/mysql/dialer/ $bu/mysql-data/dialer");
system("rsync  --exclude 'projects/workqueue' --exclude 'recordings' --exclude 'projects/log' --delete-before --delete-excluded -a /dialer/projects/ $bu/projects");

# copy sbn2 from db0 to local
system("rsync --delete-before -a -e 'ssh -p 8946' 10.9.2.15:/root/mysql/sbn2/ $bu/mysql-data/sbn2");

# make a remote copy of the data - to w7
system("rsync --delete-before -a -e 'ssh -p 8946' $bu/ root\@10.9.2.7:/sbndials-backup");

# make offsite copy of the data
system("rsync -a --delete-before -e 'ssh -p 22' $bu/ root\@24.234.118.147:/sbndials-backup");
