#!/usr/bin/perl

package Distributor;

use strict;
use warnings;

use Apache2::Const qw(:methods :common);

sub dist2res {
	my $distCode = shift;

	return 3 if $distCode eq 'daven873hgy3E6d8cNhw3dig830O0shf';
	return 8 if $distCode eq 'csimonsen57297502kkjgi28aqq17xxz';
	return 0;
}

sub handler {
	my $r = shift;

	my $req = Apache2::Request->new($r, 
		POST_MAX => 10*1024,
		DISABLE_UPLOADS => 1);

	my %data;
	DialerUtils::formdata($req, \%data);
	my $dbh = DialerUtils::db_connect(); 

	my $master = dist2res($data{'RS_DistribCode'});

	if ($master > 0) {
		if ($r->method_number == Apache2::Const::M_POST) {
			while (1) { # for jumping out of
				# validation
				my $mst = $dbh->selectrow_hashref("select RS_Credit
					from reseller where RS_Number = $master");
				if (! defined($mst->{'RS_Credit'})) {
					$data{'TransferErrStr'} = 'Master reseller was not found';
					last;
				}

				my $slv = $dbh->selectrow_hashref("select RS_Credit, RS_DistribCode, RS_DistribFactor
					from reseller  where RS_Number = " .  $data{'X_Slave_RS_Number'});
				if (! defined($slv->{'RS_Credit'})) {
					$data{'TransferErrStr'} = 'Sub-reseller was not found';
					last;
				}
				if ((!defined($slv->{'RS_DistribCode'})) ||
					($slv->{'RS_DistribCode'} ne $data{'RS_DistribCode'})) {
					$data{'TransferErrStr'} = 'Sub-reseller does not belong to this master';
					last;
				}
				if ((!defined($slv->{'RS_DistribFactor'})) ||
					($slv->{'RS_DistribFactor'} <= 1.0)) {
					$data{'TransferErrStr'} = 'Sub-reseller has bogus factor';
					last;
				}

				my $masterSign = '-';
				my $slaveSign = '+';
				my $slaveAmount = sprintf('%f', $data{'X_TransferAmount'});
				if ($slaveAmount == 0) {
					$data{'TransferErrStr'} = 'Transfer amount is invalid';
					last;
				}
				if ($slaveAmount < 0) {
					$slaveAmount = abs($slaveAmount);
					$slaveSign = '-';
					$masterSign = '+';

					if ($slaveAmount > $slv->{'RS_Credit'}) {
						$data{'TransferErrStr'} = 'Insufficient sub-reseller credit available';
						last;
					}
				}

				my $masterAmount = $slaveAmount / $slv->{'RS_DistribFactor'};
				if (($masterSign eq '-') && ($masterAmount > $mst->{'RS_Credit'})) {
					$data{'TransferErrStr'} = 'Insufficient master credit available';
					last;
				}

				# transfer
				warn("Master reseller $master: $masterSign$masterAmount; sub reseller " .
						$data{'X_Slave_RS_Number'} . ": $slaveSign$slaveAmount");
				$dbh->do("update reseller set RS_Credit = RS_Credit $masterSign $masterAmount where RS_Number = $master");
				$dbh->do("update reseller set RS_Credit = RS_Credit $slaveSign $slaveAmount where RS_Number = " . 
					$data{'X_Slave_RS_Number'} . " and RS_DistribCode = '" .
					$data{'RS_DistribCode'} . "'");

				last;
			}

		}

		if (length($data{'ErrStr'}) == 0) {
			my $res = $dbh->selectrow_hashref("select RS_Number,RS_Name,format(RS_Credit,2) as RS_Credit from reseller where RS_Number = $master");
			$data{'master'} = $res;
			$res = $dbh->selectall_arrayref("select RS_Number,RS_Name,RS_Rate,RS_RoundBy,format(RS_Credit,2) as RS_Credit,RS_DistribFactor as fact, RS_DistribCode from reseller where RS_DistribCode = '" .
				$data{'RS_DistribCode'} . "' order by RS_Number", { Slice => {} });
			$data{'resrows'} = $res;
		}
	} else {
		$data{'ErrStr'} = 'Invalid Code';
	}
	$dbh->disconnect;

	# render the page
	$req->content_type('text/html');
	my $tt = Template->new(INCLUDE_PATH => '/dialer/www/perl')
		|| die $Template::ERROR, "\n";
	$tt->process('Distributor.tt2', \%data) || die $tt->error(), "\n";

	return Apache2::Const::OK;
}
1;
