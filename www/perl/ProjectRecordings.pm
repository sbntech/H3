#!/usr/bin/perl

package ProjectRecordings;

use strict;
use warnings;

use Apache2::Const qw(:methods :common);

sub build_listings {
	my $recdir = shift;
	my $data = shift;

	$data->{'wavList'} = [];
	$data->{'zipList'} = [];

	my @ents;
	if(opendir(REC, $recdir)) {
		@ents = sort grep(/^.*\.(zip|wav)/, readdir(REC));
		closedir(REC);
	} else {
		$data->{'ErrStr'} .= "Failed opening $recdir: $!";
		return;
	}

	for my $fn (@ents) {
		my ($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size,
			$atime,$mtime,$ctime,$blksize,$blocks) = stat("$recdir/$fn");
		next if ((! $size) || ($size == 0));

		my $ext = $fn;
		$ext =~ s/.*\.(\w{3})$/$1/;

		my $szstr = DialerUtils::pretty_size($size);

		my %tcol;
		$tcol{'FileName'} = $fn;
		$tcol{'Extension'} = $ext;
		$tcol{'Size'} = $size;
		$tcol{'SizeStr'} = $szstr;
		$tcol{'Modified'} = $mtime;

		if ($ext eq 'wav') {
			push(@{$data->{'wavList'}}, \%tcol);
		} else {
			push(@{$data->{'zipList'}}, \%tcol);
		}
	}

}
	
sub handler {
	my $r = shift;

	my $req = Apache2::Request->new($r, 
		POST_MAX => 2*1024*1024,
		DISABLE_UPLOADS => 1);

	my $dbh = DialerUtils::db_connect(); 
	my $data = DialerUtils::step_one($req, $dbh,
		$req->param->{'CO_Number'}, 
		$req->param->{'PJ_Number'});

	my $recdir = '/dialer/projects/_' . $data->{'PJ_Number'} . '/recordings';

	if ((defined($data->{'ErrStr'})) && (length($data->{'ErrStr'}) > 0)) {
		$data->{'ErrStr'} .= "\nAuthorization failed";
	} elsif ($data->{'Z_PJ_Permitted'} ne 'Yes') {
		$data->{'ErrStr'} .= " Not authorized. Try to login again";
	} else { 
		# logged in so ...
		if ($req->param->{'recfilename'}) {
			my $e = $req->param->{'recfilename'};
			my $recf = "$recdir/$e";
			$e =~ s/.*\.(\w{3})/$1/; # extension

			if ($e eq 'wav') {
				my $subreq = $r->lookup_file($recf);
				$subreq->content_type('audio/x-wav');
				return $subreq->run;
			} elsif ($e eq 'zip') {
				my $subreq = $r->lookup_file($recf);
				$subreq->content_type('application/zip');
				return $subreq->run;
			} else {
				$data->{'ErrStr'} = "Bad extension: $e";
			}
		}	

		build_listings($recdir, $data);

		$dbh->disconnect;
	}

	# render the page
	$req->content_type('text/html');
	my $tt = Template->new(INCLUDE_PATH => '/dialer/www/perl')
		|| die $Template::ERROR, "\n";
	$tt->process('ProjectRecordings.tt2', $data) || die $tt->error(), "\n";

	return Apache2::Const::OK;
}
1;
