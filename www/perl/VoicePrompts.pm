#!/usr/bin/perl

package VoicePrompts;

use strict;
use warnings;

use Apache2::Const qw(:methods :common);

sub handler {
	my $r = shift;

	my $spoolbucket = '/home/www-data/VoicePrompts';
	mkdir $spoolbucket unless -d $spoolbucket;

	my $req = Apache2::Request->new($r, 
		POST_MAX => 20*1024*1024,
		DISABLE_UPLOADS => 0,
		TEMP_DIR => $spoolbucket);

	my $dbh = DialerUtils::db_connect(); 
	my $data = DialerUtils::step_one($req, $dbh,
		$req->param->{'CO_Number'}, 
		$req->param->{'PJ_Number'});

	$data->{'Method'} = $req->param->{'m'} ? $req->param->{'m'} : 'show';

	my ($d, $t) = DialerUtils::local_datetime();
	$t =~ s/://g;

	if ((defined($data->{'ErrStr'})) && (length($data->{'ErrStr'}) > 0)) {
		$data->{'ErrStr'} .= "\nAuthorization failed";
	} elsif ($data->{'Z_PJ_Permitted'} ne 'Yes') {
		$data->{'ErrStr'} .= " Not authorized. Try to login again";
	} else { 
		# logged in so ...
		my $vdir = "/dialer/projects/_" . $data->{'PJ_Number'} . "/voiceprompts";
		if (! -d $vdir) {
			mkdir $vdir;
		}
		my $custvdir = "/dialer/projects/voicecust/_" . $data->{'CO_Number'};
		if (! -d $custvdir) {
			mkdir $custvdir;
		}

		# figure out which file is being referred to
		my $dir = '/tmp';
		my $fn = 'unknown.wav';
		my $lev = 'Proj';
		my $mvdir;
		if (defined($req->param->{'ProjFileName'})) {
			$fn = $req->param->{'ProjFileName'};
			$dir = $vdir;
			$mvdir = $custvdir;
			$lev = 'Proj';
		} elsif (defined($req->param->{'CustFileName'})) {
			$fn = $req->param->{'CustFileName'};
			$dir = $custvdir;
			$mvdir = $vdir;
			$lev = 'Cust';
		}
		$fn =~ /(.*)\.(wav|vox|mp3)$/;
		my ($base, $ext) = ($1, $2);

		if ($data->{'Method'} eq 'download') {
			if (-f "$dir/$fn") {
				if ($ext eq 'vox') {
					my $listen = "$dir/download-and-listen.system.wav";
					system("sox -t ul -r 8000 -c 1 '$dir/$fn' -r 8000 -c 1 '$listen'");
					$req->content_type('audio/x-wav');
					$req->headers_out->set('Content-disposition' => "filename=\"$base.wav\"");
					$req->sendfile($listen);
					unlink($listen);
					return Apache2::Const::OK;
				} else {
					if ($ext eq 'mp3') {
						$req->content_type('audio/x-wav');
					} else {
						$req->content_type('audio/x-wav');
					}
					$req->headers_out->set('Content-disposition' => "filename=\"$fn\"");
					$req->sendfile("$dir/$fn");
					return Apache2::Const::OK;
				}
			}
		} elsif ($data->{'Method'} eq 'record') {
			$data->{'X_Recording_PIN'} = int(rand() * 9000) + 1000;

			use AstManager;
			my $ast = new AstManager('sbnmgr', 'iuytfghd', '67.209.46.100');

			$ast->send_action("DBPut", {
				'Family'	=> 'MsgRec',
				'Key'		=> $data->{'X_Recording_PIN'},
				'Val'		=> $data->{'PJ_Number'}
				},{
				'Response'	=> 'Success',
				'Message'	=> 'Updated database successfully'
				});

			$ast->recv_responses();
			$ast->disconnect;

		} elsif ($data->{'Method'} eq 'delete') {
			if ($dir ne '/tmp') {
				if (($fn =~ /^(live|machine)\.vox$/) && ($lev eq 'Proj')) {
					my $a = $1;
					system("mv '$dir/$fn' '$dir/$a-$d-$t.vox'");
				} else {
					unlink("$dir/$fn");
					print STDERR "INFO: deleted $dir/$fn \n";
				}
			}
		} elsif ($data->{'Method'} eq 'rename') {
			my $newname = lc($req->param->{'NewFileName'});
			if ($fn =~ /(live|machine)\.vox/) {
				my $a = $1;
				system("cp '$dir/$fn' '$dir/$a-$d-$t.vox'");
			}
			if (($newname =~ /(live|machine)\.vox/) && (-f "$dir/$newname")) {
				my $a = $1;
				system("mv '$dir/$newname' '$dir/$a-$d-$t.vox'");
			}

			system("mv '$dir/$fn' '$dir/$newname'");
		} elsif ($data->{'Method'} eq 'copy') {
			if ($dir ne '/tmp') {
				system("cp -p '$dir/$fn' '$mvdir/'");
			}
		}

		if ($r->method_number == Apache2::Const::M_POST) {
			if ($data->{'Method'} eq 'load') {
				for my $n ($req->upload) {
					my $u = $req->upload($n);
					next if ($u->size <= 0);

					# IE sends names like P:\mydir\myfile.txt
					my $base = $u->filename;
					$base =~ /([^\\\/]*)\.(wav|vox|mp3)$/;
					$base = lc($1);
					$base =~ tr/-a-z //cd;
					my $ext = $2;

					print STDERR "INFO: Voice file: " . $u->filename . " loaded from " . $u->tempname . 
							" having base=$base extension=$ext into $vdir\n";

					if (($base eq 'live') || ($base eq 'machine')) {
						system("mv '$vdir/$base.vox' '$vdir/$base-$d-$t.vox'");
					}

					my $vname = "$vdir/$base.vox";
					if ($ext eq 'vox') {
						system("mv '" . $u->tempname . "' '$vname'");
					} else {
						system("mv '" . $u->tempname . "' '$vdir/s-o-m-e-t-h-i-n-g.$ext'");
						system("sox '$vdir/s-o-m-e-t-h-i-n-g.$ext' -t ul -r 8000 -c 1 '$vname'");
						unlink("$vdir/s-o-m-e-t-h-i-n-g.$ext");
					}
					system("chmod 0644 '$vname'");

				}
			}
		} 

		# prepare the list of project files
		my @projectfiles;
		if (opendir PJF, $vdir) {
			while (my $ent = readdir PJF) {
				next if $ent =~ /^\.*$/;
				next if $ent =~ /^(live|machine)-20\d\d-\d\d-\d\d-\d{6}\.vox$/;
				my ($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size,
				       $atime,$mtime,$ctime,$blksize,$blocks)
		           = stat("$vdir/$ent");
				my ($mdatestr, $mtimestr) = DialerUtils::local_datetime($mtime);
				push @projectfiles, {
					FileName 	=> $ent,
					Size		=> sprintf("%0.1f", $size / 1000),
					VoxLength	=> int($size / 8000),
					Modified	=> "$mdatestr $mtimestr"
				};
			}
			closedir PJF;
		}
		my @splist = sort({ $a->{'Modified'} cmp $b->{'Modified'} } @projectfiles);
		$data->{'ProjectFiles'} = \@splist;

		# prepare the list of customer files
		my @customerfiles;
		if (opendir CF, $custvdir) {
			while (my $ent = readdir CF) {
				next if $ent =~ /^\.*$/;
				my ($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size,
				       $atime,$mtime,$ctime,$blksize,$blocks)
		           = stat("$custvdir/$ent"); 
				my ($mdatestr, $mtimestr) = DialerUtils::local_datetime($mtime);
				push @customerfiles, {
					FileName 	=> $ent,
					Size		=> sprintf("%0.1f", $size / 1000),
					VoxLength	=> int($size / 8000),
					Modified	=> "$mdatestr $mtimestr"
				};
			}
			closedir CF;
		}
		my @sclist = sort({ $a->{'FileName'} cmp $b->{'FileName'} } @customerfiles);
		$data->{'CustomerFiles'} = \@sclist;
		

		$dbh->disconnect;
	} # else

	# render the page
	$req->content_type('text/html');
	my $tt = Template->new(INCLUDE_PATH => '/dialer/www/perl')
		|| die $Template::ERROR, "\n";
	$tt->process('VoicePrompts.tt2', $data) || die $tt->error(), "\n";

	return Apache2::Const::OK;
}
1;
