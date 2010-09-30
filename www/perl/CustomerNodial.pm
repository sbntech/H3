#!/usr/bin/perl

package CustomerNodial;

use strict;
use warnings;

use Apache2::Const qw(:methods :common);

sub merge_list {
	my $lfile = shift;
	my $custid = shift;
	
	# clean the data
	DialerUtils::clean_file($lfile, $lfile);

	my @nums;
	if (open(NUMS, '<', $lfile)) {
		while (my $num = <NUMS>) {
			push @nums, $num;
		}
		close NUMS;
		unlink($lfile);
		DialerUtils::custdnc_add($custid, \@nums);
	} else {
		warn "Merging $lfile for customer $custid failed: $!";
	}
}

sub upload {
	my $dbh = shift;
	my $req = shift;
	my $data = shift;
	
	for my $n ($req->upload) {
		my $u = $req->upload($n);
		next if ($u->size <= 0);

		# IE sends names like P:\mydir\myfile.txt
		my $base = $u->filename;
		$base =~ s/.*(\\|\/)(.*)/$2/;

		my $zoutf = '/tmp/CustDNC/' . $data->{'CO_Number'} . '.dnczip';

		if ($base =~ /\.zip$/i) {
			system('unzip -q -j -p ' . $u->tempname . " > $zoutf");
			merge_list($zoutf, $data->{'CO_Number'});
		} elsif ($base =~ /\.txt$/i) {
			merge_list($u->tempname, $data->{'CO_Number'});
		} else {
			$data->{'ErrStr'} = " $base did not have a recognized file type";
		}
	}
}

sub handler {
	my $r = shift;

	mkdir('/tmp/CustDNC') unless (-d '/tmp/CustDNC');

	my $req = Apache2::Request->new($r, 
		POST_MAX => 40*1024*1024,
		DISABLE_UPLOADS => 0,
		TEMP_DIR => '/tmp/CustDNC');

	my $dbh = DialerUtils::db_connect(); 
	my $data = DialerUtils::step_one($req, $dbh,
		$req->param->{'CO_Number'}, 0);

	$data->{'DncListSize'} = 0;
	$data->{'m'} = 'show' if ((!defined($data->{'m'})) || ($data->{'m'} eq ''));

	if ((defined($data->{'ErrStr'})) && (length($data->{'ErrStr'}) > 0)) {
		$data->{'ErrStr'} .= "\nAuthorization failed";
	} elsif ($data->{'Z_CO_Permitted'} ne 'Yes') {
		$data->{'ErrStr'} .= " Not authorized. Try to login again";
	} else { 
		# logged in so ...
		if ($r->method_number == Apache2::Const::M_POST) {
			if ($data->{'m'} eq 'show') {
				# no op - just show it
			} elsif ($data->{'m'} eq 'upload') {
				# handle the textarea
				if (length($data->{'numberarea'}) > 9) {
					my $tafile = '/tmp/CustDNC/' . $data->{'CO_Number'} . '-tadnc-' . rand();
					open(TA, ">", $tafile);
					print TA $data->{'numberarea'};
					close(TA);
					merge_list($tafile, $data->{'CO_Number'});
				}

				# upload files
				upload($dbh, $req, $data);
			} elsif ($data->{'m'} eq 'check') {
				# check a number
				my $checknum = DialerUtils::north_american_phnumber($data->{'checknumber'});
				my $sbn2 = DialerUtils::sbn2_connect();
				my $cdnc = $sbn2->selectrow_hashref("select * from custdnc 
					where CD_PhoneNumber = $checknum");
				if (defined($cdnc->{'CD_PhoneNumber'})) {
					$data->{'CheckResult'} = $cdnc;
				} else {
					$data->{'CheckResultNotFound'} = $checknum;
				}
				$sbn2->disconnect();
			} else {
				$data->{'ErrStr'} = 'm=' . $data->{'m'} . ' not understood';
			}
		} elsif ($data->{'m'} eq 'download') {
			# download a list
			my $cust = $data->{'CO_Number'};
			my $outfile = "/var/lib/mysql/dialer/$cust-DNC.txt";
			my $target = "/tmp/$cust-DNC";
			my $sbn2 = DialerUtils::sbn2_connect();
			my $cdnc = $sbn2->do("select CD_PhoneNumber from custdnc 
				where CD_LastContactDT > date_sub(current_date(), interval 90 day)
				and (CD_LastContactCust = $cust or CD_AddedCust = $cust)
				into outfile '$outfile'");
			$sbn2->disconnect();
			DialerUtils::move_from_db($outfile, "$target.txt");
			system("zip -q -j $target.zip $target.txt");
			unlink("$target.txt");

			my $subreq = $r->lookup_file("$target.zip");
			my $attachfile = 'Customer-' . $data->{'CO_Number'} . '-DoNotCall.zip';
			$subreq->content_type('application/zip');
			$req->headers_out->set('Content-disposition', "attachment; filename=\"$attachfile\"");
			return $subreq->run;
		}

	}
	$dbh->disconnect;

	# render the page
	$req->content_type('text/html');
	my $tt = Template->new(INCLUDE_PATH => '/dialer/www/perl')
		|| die $Template::ERROR, "\n";
	$tt->process('CustomerNodial.tt2', $data) || die $tt->error(), "\n";

	return Apache2::Const::OK;
}
1;
