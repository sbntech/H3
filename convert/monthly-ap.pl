#!/usr/bin/perl

use strict;
use warnings;

use lib '/dialer/www/perl';
use DialerUtils;
use Logger;
use CreditCard;
use Crypt::CBC;
use Net::SMTP;
use JSON;

my $me = DialerUtils::who_am_I();
my $TESTING = 0;

if ($me eq 'swift') {
	$TESTING = 1;
}

my $logfile = '/var/log/monthly-w0.log';
my $log = Logger->new($logfile);

my $FROM    = "\"Dialer\" <root\@quickdials.com>";
my $SBNTO   = "support\@quickdials.com";
my $CARLTO  = "support\@bullseyebroadcast.com";
my $SUBJECT = "Monthly Processing Report";

if ($TESTING) {
	$SBNTO = "\"SBN Tech\" <tech\@quickdials.com>";
	$CARLTO = "\"CARL-TEST\" <grant\@quickdials.com>";
	$SUBJECT = "[TESTMODE] $SUBJECT";
}

my $emailCARL = "To: $CARLTO\nFrom: $FROM\nSubject: $SUBJECT\n\nMonthly Processing for Bullseye Broadcast\n\n";
my $emailSBN  = "To: $SBNTO\nFrom: $FROM\nSubject: $SUBJECT\n\nMonthly Processing\n\n";

# connect to the database
my $dbh = DialerUtils::db_connect(); 
my $aff;
my $lastRes = -99;

sub report {
	my $reseller = shift;
	my $msg = shift;

	$log->info($msg);
	$emailSBN .= "$msg\n";

	if ($reseller == 77) {
		$emailCARL .= "$msg\n";
	}
}

sub log_change {
	my $AC = shift;
	my $error = shift;

	$aff = $dbh->do("insert into agentcharge
		(AC_Customer, AC_DateTime, AC_AgentsBefore, AC_AgentsAfter,
		 AC_CustCharge, AC_ResCharge, AC_Error) values 
		('" . $AC->{'AC_Customer'} . "', now(), '" .
		$AC->{'AC_AgentsBefore'} . "', '" . 
		$AC->{'AC_AgentsAfter'} . "', '" . 
		$AC->{'AC_CustCharge'} . "', '" .
		$AC->{'AC_ResCharge'} . "', '$error')"); 

	if ($aff == 1) {
		$log->info("agentcharge table insert succeeded");
	} else {
		$log->error("agentcharge table insert failed: " 
			. $dbh->{'mysql_error'});
	}
}

sub do_agent_charges {

	report(77, "\n\nAgent Charges:");

	# find customers
	# note: the "CO_Credit > 0" is redundant because of the above fix
	my $res = $dbh->selectall_arrayref("select * from customer, reseller
		where CO_ResNumber = RS_Number
		and CO_AgentCharge > 0 and CO_AuthorizedAgents > 0 
		and CO_Status = 'A' and CO_Credit > 0
		order by CO_ResNumber", { Slice => {}});

	CUSTOMER: for my $row (@$res) {

		my $resDesc = sprintf('Reseller %d {%s} - AgentCharge=%0.2f AgentChargePerc=%0.5f',
			$row->{'RS_Number'}, $row->{'RS_Name'},
			$row->{'RS_AgentCharge'}, $row->{'RS_AgentChargePerc'});

		if ($row->{'RS_Number'} != $lastRes) {
			report($row->{'RS_Number'}, "=====> $resDesc <=====");
			$lastRes = $row->{'RS_Number'};
		}

		my $custDesc = sprintf('Customer %d {%s} with %d agents at %0.5f per month having credit of %0.5f',
			$row->{'CO_Number'},
			$row->{'CO_Name'},
			$row->{'CO_AuthorizedAgents'},
			$row->{'CO_AgentCharge'},
			$row->{'CO_Credit'});

		report($row->{'RS_Number'}, "-----> $custDesc");

		my $AC = {
			'AC_Customer' => $row->{'CO_Number'},
			'AC_AgentsBefore' => $row->{'CO_AuthorizedAgents'},
			'AC_AgentsAfter' => $row->{'CO_AuthorizedAgents'},
			'AC_CustCharge' => 0,
			'AC_ResCharge' => 0,
		};


		# determine the customer's charge
		# note: CO_AgentCharge guaranteed > 0 by select
		my $funded = int($row->{'CO_Credit'} / $row->{'CO_AgentCharge'});
		$funded = 0 if ($funded < 0);

		if ($funded < $row->{'CO_AuthorizedAgents'}) {
			# fix customers who have more agents than they can afford
			$aff = $dbh->do("update customer set CO_AuthorizedAgents = $funded
				where CO_Number = " . $row->{'CO_Number'});
			if ($aff == 1) {
				report($row->{'RS_Number'}, "Customer had non-sufficient funds, AuthorizedAgents reduced from "
					. $row->{'CO_AuthorizedAgents'} . " to $funded");
				 $row->{'CO_AuthorizedAgents'} = $funded;
			} else {
				report($row->{'RS_Number'}, "Database error attempting to reduce AuthorizedAgents");
				$log->error("Update of customer failed attempting to reduce AuthorizedAgents: " 
					. $dbh->{'mysql_error'});
				log_change($AC, "database failed to reduce authorized agents to $funded");
				next CUSTOMER;
			}
		}
		$AC->{'AC_AgentsAfter'} = $row->{'CO_AuthorizedAgents'};
		my $custCharge = $row->{'CO_AuthorizedAgents'} * $row->{'CO_AgentCharge'};
		my $prettyCharge = sprintf('%0.5f', $custCharge);

		# charge the customer
		$aff = $dbh->do("update customer set CO_Credit = CO_Credit - $custCharge
			where CO_Number = " . $row->{'CO_Number'} . " limit 1");
		if ($aff == 1) {
			report($row->{'RS_Number'}, "Customer charged: $prettyCharge");
			$AC->{'AC_CustCharge'} = $custCharge;
		} else {
			report($row->{'RS_Number'}, "Database error attempting to apply charge of $prettyCharge");
			$log->error("Update of customer failed attempting to apply charge of $prettyCharge: " 
				. $dbh->{'mysql_error'});
			log_change($AC, "database failed to charge customer $custCharge");
			next CUSTOMER;
		}
		
		# determine the reseller's charge
		if ($row->{'RS_Number'} == 1) {
			log_change($AC, '');
			next CUSTOMER;
		}

		my $resCharge = (($custCharge * $row->{'RS_AgentChargePerc'}) / 100)
			+ ($row->{'CO_AuthorizedAgents'} * $row->{'RS_AgentCharge'});
		$prettyCharge = sprintf('%0.5f', $resCharge);

		# bill the reseller (they can go negative)
		$aff = $dbh->do("update reseller set RS_Credit = RS_Credit - $resCharge
			where RS_Number = " . $row->{'RS_Number'} . " limit 1");
		if ($aff == 1) {
			report($row->{'RS_Number'}, "Reseller charged $prettyCharge");
			$AC->{'AC_ResCharge'} = $resCharge;
			log_change($AC, '');
		} else {
			report($row->{'RS_Number'}, "Database error while updating reseller to charge $prettyCharge");
			$log->error("Update of reseller failed attempting to charge $prettyCharge: " 
				. $dbh->{'mysql_error'});
			log_change($AC, "database failed to charge reseller $resCharge");
		}
	}
}


sub do_periodic_payments {

	report(77, "\nPeriodic Payments:");

	my $s = DialerUtils::tellSecret();
	die "Blowfish not swimming" unless $s;

	# find customers
	my $res = $dbh->selectall_arrayref(
		"select * from periodicpay, customer
		where PP_Customer = CO_Number", { Slice => {}});

	PPAY: for my $row (@$res) {

		my $CO_Number = $row->{'PP_Customer'};

		my $cc = CreditCard->forge($TESTING);

		# decrypt PP_CardDetails and populate $cc
		my $iv = $row->{'PP_Last4'} . $row->{'PP_Last4'};

		my $cipher = Crypt::CBC->new
			( 	-key => $s,
				-cipher => 'Blowfish',
				-header => 'none',
				-iv		=> $iv);

		my $decyphered = $cipher->decrypt_hex($row->{'PP_CardDetails'});
		my $ccHash = JSON::from_json($decyphered);

		for my $k (keys %$ccHash) { 
			$cc->{$k} = $ccHash->{$k};
		}

		my $merchant = 'SBN';
		$merchant = 'CARL' if ($row->{'CO_ResNumber'} == 77);

		my $API_Response = $cc->sale($row->{'PP_ChargeAmount'}, $merchant);

		my $errstr = '';
		if ($API_Response->{'Attribute_Errors'}) {
			for my $k (keys %{$API_Response->{'Attribute_Errors'}}) {
				$errstr .= $API_Response->{'Attribute_Errors'}{$k} . "; ";
			}
		} else {
			if (defined($API_Response->{'Processing_Error'})) {
				$errstr .= $API_Response->{'Processing_Error'};
			}
		}

		if (length($errstr) > 5) {
			# sale failed
			report($row->{'CO_ResNumber'}, "Customer $CO_Number (" .
				$row->{'CO_Name'} . ") ppay failed: $errstr");

			$dbh->do("update periodicpay
				set PP_Error = '$errstr'
				where PP_Customer = $CO_Number");
		} else {
			# sale succeeded
			report($row->{'CO_ResNumber'}, "Customer $CO_Number (" .
				$row->{'CO_Name'} . ") ppay succeeded, took \$" .
				$row->{'PP_ChargeAmount'} . " from credit card");

			$dbh->do("update periodicpay
				set PP_Error = null,
				PP_LastPayDT = now()
				where PP_Customer = $CO_Number");

			my ($rc, $rmsg) = DialerUtils::add_credit($dbh, 
				'Mode' 		=> 'customer',
				'Amount'    => $row->{'PP_ChargeAmount'},
				'Id_Number' => $CO_Number,
				'ac_user'   => 'sys_ppay',
				'ac_ipaddress' => $me
			);
			if (! $rc) {
				report($row->{'CO_ResNumber'}, "Updating system balance: for customer $CO_Number (" .
					$row->{'CO_Name'} . ") by \$" .	$row->{'PP_ChargeAmount'} 
					. " failed. $rmsg");
			} else {
				report($row->{'CO_ResNumber'}, "Updating system balance succeeded for customer $CO_Number (" .
					$row->{'CO_Name'} . ") by \$" .	$row->{'PP_ChargeAmount'});
			}

		}

	}

}
# ==== Main

do_periodic_payments();
do_agent_charges();

$dbh->disconnect;

# email the reports
my $smtp = Net::SMTP->new("10.9.2.1", Timeout => 60, Debug => 0);
if ($smtp) {
	$smtp->mail($FROM);
	$smtp->to($SBNTO);
	$smtp->data();
	$smtp->datasend($emailSBN);
	$smtp->dataend();
	$smtp->mail($FROM);
	$smtp->to($CARLTO);
	$smtp->data();
	$smtp->datasend($emailCARL);
	$smtp->dataend();
	$smtp->quit;
} else {
	warn "failed to smtp: $!";
}

$log->debug("Terminating");
$log->fin;
