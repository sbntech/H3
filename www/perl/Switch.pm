#!/usr/bin/perl

package Switch;

use strict;
use warnings;

use Apache2::Const qw(:methods :common);

sub handler {
	my $r = shift;

	my $req = Apache2::Request->new($r, 
		POST_MAX => 10*1024,
		DISABLE_UPLOADS => 1);

	my $template = 'SwitchDetail.tt2';
	my $data = {};
	DialerUtils::formdata($req, $data);
	my $dbh = DialerUtils::db_connect();

	$data->{'method'} = 'show' unless defined($data->{'method'});

	if (defined($data->{'switch'})) {
		if ($data->{'method'} eq 'block') {
			my $affected = $dbh->do(
				"update switch set SW_Status='B' where SW_ID='" .
				$data->{'switch'} . "'");
			$data->{'MessageStr'} .= "$affected switch blocked, ";

			$affected = $dbh->do("update line set ln_status='B'," .
				"ln_action ='888888' where ln_status != 'O' and ln_switch='" . $data->{'switch'} . "'");
			$data->{'MessageStr'} .= "$affected lines blocked";
		} elsif ($data->{'method'} eq 'board') {
			my $affected = $dbh->do("update line set ln_status='B'," .
				"ln_action ='888888' where ln_switch='" . $data->{'switch'} . 
				"' and ln_board = '" . $data->{'board'} . 
				"' and ln_status != 'D' and ln_status != 'E'");
			warn("$affected lines blocked on board " . $data->{'switch'}
				. '-' . $data->{'board'});
		} elsif ($data->{'method'} eq 'asterisk') {
			my $cps = $data->{'SW_VoipCPS'};
			$cps = 0 unless ((defined($cps)) && ($cps >= 0));
			my $ports = $data->{'SW_VoipPorts'};
			$ports = 0 unless ((defined($ports)) && ($ports >= 0));

			# save them
			$dbh->do("update switch set SW_VoipCPS = $cps, 
					SW_VoipPorts = $ports 
					where SW_ID = '" . $data->{'switch'} . "' limit 1");

			# detemine current ports
			my $r = $dbh->selectrow_hashref("select count(*) as Total
				from line where ln_switch = '" . $data->{'switch'} . "'
				and ln_status != 'B'");
			my $curPorts = $r->{'Total'};

			# block/unblock what we need to
			if ((defined($curPorts)) && ($curPorts >= 0) && (defined($ports)) && ($ports >= 0)) {
				my $actual = 0;
				my $deltaPorts = $ports - $curPorts;
				if ($deltaPorts > 0) {
					$actual = $dbh->do("update line set ln_status = 'F' where ln_status = 'B' and ln_switch = '" . $data->{'switch'} . "' limit $deltaPorts");
				} elsif ($deltaPorts < 0) {
					my $limit = -$deltaPorts;
					$actual = $dbh->do("update line set ln_status = 'B' where ln_status != 'B' and ln_switch = '" . $data->{'switch'} . "' limit $limit");
				}
				$data->{'MessageStr'} .= "Changing ports from $curPorts to $ports (delta=$deltaPorts). Actually changed $actual";
			}


		} elsif ($data->{'method'} eq 'reset') {
			# X is a flag to the nvr to reset it, which changes status to E
			my $affected = $dbh->do(
				"update switch set SW_Status='X' where SW_ID='" .
				$data->{'switch'} . "'");
			$data->{'MessageStr'} .= "$affected switch reset, ";

			$affected = $dbh->do("update line set ln_status='E'," .
				"ln_action ='' where ln_switch='" . $data->{'switch'} . "'");
			$data->{'MessageStr'} .= "affecting $affected lines";
		}

		# render the page
		if (substr($data->{'switch'},0,1) eq 'W') {
			$data->{'SwitchType'} = 'ASTERISK';
		} else {
			$data->{'SwitchType'} = 'NVR';
			$data->{'boardlist'} = $dbh->selectall_arrayref(
				"select floor(ln_board) as Board, 
					sum(if(ln_status = 'E',1,0)) as Errors,
					sum(if(ln_status = 'B',1,0)) as Blocked,
					sum(if(ln_status = 'U',1,0)) as Used,
					sum(if(ln_status = 'S',1,0)) as Stop,
					sum(if(ln_status = 'F',1,0)) as Free,
					sum(if(ln_status = 'O',1,0)) as Open,
					sum(if(ln_status = 'D',1,0)) as Data
				from line 
					where ln_switch = '" . $data->{'switch'} . "'
					group by floor(ln_board) 
					order by floor(ln_board)", { Slice => {}});
		}

		$data->{'row'} = $dbh->selectrow_hashref("select * from switch where SW_ID = '" . $data->{'switch'} . "'");
		$req->content_type('text/html');
		my $tt = Template->new(INCLUDE_PATH => '/dialer/www/fancy:/dialer/www/perl', RELATIVE => 1,)
			|| die $Template::ERROR, "\n";
		$tt->process($template, $data) || die $tt->error(), "\n";

		return Apache2::Const::OK;
	}

	$dbh->disconnect;

	return Apache2::Const::DECLINED;
}
1;
