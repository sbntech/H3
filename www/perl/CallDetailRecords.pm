#!/usr/bin/perl

package CallDetailRecords;

use strict;
use warnings;

use Apache2::Const qw(:methods :common);
	
sub handler {
	my $r = shift;

	my $req = Apache2::Request->new($r, 
		POST_MAX => 2*1024*1024,
		DISABLE_UPLOADS => 1);

	my $dbh = DialerUtils::db_connect(); 
	my $data = DialerUtils::step_one($req, $dbh,
		$req->param->{'CO_Number'}, 
		$req->param->{'PJ_Number'});

	my $cdrdir = '/dialer/projects/_' . $data->{'PJ_Number'} . '/cdr';

	if ((defined($data->{'ErrStr'})) && (length($data->{'ErrStr'}) > 0)) {
		$data->{'ErrStr'} .= "\nAuthorization failed";
	} elsif ($data->{'Z_PJ_Permitted'} ne 'Yes') {
		$data->{'ErrStr'} .= " Not authorized. Try to login again";
	} else { 
		# logged in so ...
		if ($r->method_number == Apache2::Const::M_POST) {
			my $tmp = '/tmp/cdr-tmp-' . $data->{'PJ_Number'};

			if ($req->param->{'searchstr'}) {
				if (length($req->param->{'searchstr'}) > 0) {
					system("(for ZFILE in $cdrdir/cdr-*.zip ; " . 
						'do unzip -q -p $ZFILE; done) | ' . # $ZFILE is a shell var
						"cat - $cdrdir/cdr-*.txt | grep -s -m 100 -F '" .
						$req->param->{'searchstr'} . "' > '$tmp'");
					my $subreq = $r->lookup_file($tmp);
					$subreq->content_type('text/plain');
					my $rc = $subreq->run;
					unlink($tmp);
					return $rc;
				}
			} elsif ($req->param->{'cdrfilename'}) {
				my $e = $req->param->{'cdrfilename'};
				my $cdrf = "$cdrdir/$e";
				$e =~ s/.*\.(\w{3})/$1/; # extension

				if ($e eq 'txt') {
					system("zip -j -q $tmp.zip $cdrdir/cdr-*.txt");
					my $subreq = $r->lookup_file("$tmp.zip");
					$subreq->content_type('application/zip');
					my $rc = $subreq->run;
					unlink($tmp);
					return $rc;
				} elsif ($e eq 'zip') {
					warn "downloading: $cdrf";
					my $subreq = $r->lookup_file($cdrf);
					$subreq->content_type('application/zip');
					return $subreq->run;
				} else {
					$data->{'ErrStr'} = "Bad extension: $e";
				}
			} else {
				$data->{'ErrStr'} = "Bad request";
			}	
		}

		# ... cdr table info
		opendir(CDR, $cdrdir) or warn "failed opening $cdrdir: $!";
		my @ents = sort grep(/^cdr-.*\.zip/, readdir(CDR));
		closedir(CDR);

		my $BPS = 512*1024/8; # bytes downloadable per second on 0.5Mbit
		my @trows;
		for my $fn (@ents) {
			my ($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size,
				$atime,$mtime,$ctime,$blksize,$blocks) = stat("$cdrdir/$fn");
			next if ((! $size) || ($size == 0));

			my $ext = $fn;
			$ext =~ s/.*\.(\w{3})$/$1/;

			my $ddursecs = int($size / $BPS);
			my $dstr;
			if ($ddursecs < 15) {
				$dstr = '< 15 secs';
			} elsif ($ddursecs < 120) {
				$dstr = "$ddursecs secs";
			} else {
				$dstr = int($ddursecs / 60) . ' mins';
			}

			my $szstr = DialerUtils::pretty_size($size);

			my %tcol;
			$tcol{'FileName'} = $fn;
			$tcol{'Extension'} = $ext;
			$tcol{'Size'} = $size;
			$tcol{'SizeStr'} = $szstr;
			$tcol{'Modified'} = $mtime;
			$tcol{'DownloadTime'} = $dstr;

			push(@trows, \%tcol);
		}

		$dbh->disconnect;
		$data->{'trows'} = \@trows;
	}

	# render the page
	$req->content_type('text/html');
	my $tt = Template->new(INCLUDE_PATH => '/dialer/www/perl')
		|| die $Template::ERROR, "\n";
	$tt->process('CdrFiles.tt2', $data) || die $tt->error(), "\n";

	return Apache2::Const::OK;
}
1;
