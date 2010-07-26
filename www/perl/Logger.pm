#!/usr/bin/perl
package Logger;

use strict;
use warnings;
use Time::HiRes qw( gettimeofday tv_interval );
use lib '/dialer/www/perl';
use DialerUtils;

=pod

USAGE

use lib '/home/grant/sbn-git/www/perl/';
use Logger;


my $log = Logger->new('/tmp/loggertest.log');

$log->info("my nice info message");
$log->debug('setting the threshold higher');

$log->threshold(1);
$log->info("my second info message");
$log->debug('verbose debuggery');
$log->fatal('oops');

$log->threshold(0);
$log->debug('thanks');

$log->fin;

=cut

# .............................................................................
sub new {
	my $class = shift;
	my $logfile = shift; # path/filename of the file to log to

	my $FH;
	open $FH, '>>', $logfile
		or die "failed to open logfile $logfile: $!";

	my $old_fh = select($FH);
	$| = 1;
	select($old_fh);

	my $self = {
		'threshold' => 0,
		'filename' => $logfile,
		'LOGFH' => $FH,
		't0' => [gettimeofday()]
	};

	bless $self, $class;

	$self->msg(99, "log file $logfile opened");

	return $self;
}

# .............................................................................
sub threshold {
	my $self = shift;
	my $level = shift;

	$self->msg(99, 'threshold level was "' .
		level2str($self->{'threshold'}) . '" (' .
		$self->{'threshold'} . ') setting it to "' .
		level2str($level) . "\" ($level)");

	$self->{'threshold'} = $level;


}

# .............................................................................
sub level2str {
	my $level = shift;

	return 'logger' if $level == 99;

	my $str = ['debug','info','warn','error','fatal']->[$level];

	$str = 'unknown' unless defined $str;
	return $str;
}

# .............................................................................
sub msg {
	my $self = shift;
	my $level = shift;

	if ($level >= $self->{'threshold'}) {
		my $lstr = level2str($level);
		die "msg called without a file to write to" unless defined($self->{'LOGFH'});

		my ($dt, $tm) = DialerUtils::local_datetime();
		my $t1 = [gettimeofday()];
		my $elapsed = tv_interval($self->{'t0'}, $t1);
		my $m = sprintf('%0.5f', $elapsed);
		$self->{'t0'}  = $t1;

		print {$self->{'LOGFH'}} "$dt $tm ($m) " . sprintf('%-6s: ', $lstr);
		print {$self->{'LOGFH'}} @_;
		print {$self->{'LOGFH'}} "\n";
	}
}

# .............................................................................
sub debug	{ my $self = shift; $self->msg(0, @_); }
sub info	{ my $self = shift; $self->msg(1, @_); }
sub warn	{ my $self = shift; $self->msg(2, @_); }
sub error	{ my $self = shift; $self->msg(3, @_); }
sub fatal	{ my $self = shift; $self->msg(4, @_); }

# .............................................................................
sub fin {
	my $self = shift;

	$self->msg(99, "log file " . $self->{'filename'} . " closed");

	close ($self->{'LOGFH'});
	$self->{'LOGFH'} = undef;
}

# .............................................................................
sub DESTROY {
	my $self = shift;

	if (defined($self->{'LOGFH'})) {
		$self->msg(99, "log file " . $self->{'filename'} . " closed in the destructor");
		close ($self->{'LOGFH'});
	}
}

1;
