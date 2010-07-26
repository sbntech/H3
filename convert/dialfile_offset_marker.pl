#!/usr/bin/perl
 
use strict;
use warnings;

open(DF, $ARGV[0]) or die "Cannot open";
my $ibuf;
read(DF, $ibuf, 4);
close(DF);

my $of = unpack("i", $ibuf);
my ($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size, $atime,$mtime,$ctime,$blksize,$blocks) = stat($ARGV[0]);

print "In-file offset marker = $of\n";
print "stat size = $size\n";
print "percent used = " . (100 * $of)/$size . "\n";
print "approx: " . int($of/11) . " of " . int($size/11) . " numbers\n";
