#!/usr/bin/perl

=pod

== BBCOM VOIP
	fixing BBCOM cdr files: use
		date; INVOICE=10708 ; tr '\r' '\n' < $INVOICE.txt > $INVOICE.fix ; mv $INVOICE.fix $INVOICE.txt ; date


== Qwest (via BBCOM)
	* get the URL from the bbcom webiste: http://customers.bbcominc.com/
		for example: http://customers.bbcominc.com/invoices/11634_4AugTo3Sep.rar
	* wget $URL
	* unrar e 11634_4AugTo3Sep.rar
	* mv 11634_4AugTo3Sep.txt /home/grant/carrier-cdr/qwest
	* rm 11634_4AugTo3Sep.rar

=cut


use strict;
use warnings FATAL => 'all';
use lib '/home/grant/H3/www/perl/';
use DialerUtils;
use lib '/home/grant/H3/convert/npanxx-data/';
use Rates;
use DateTime;
use JSON;

$| = 1; # unbuffered output
my $LOCALDIR='/home/grant/carrier-cdr';
my $RESULTSDIR = "$LOCALDIR/results";
my $SBNRESULTSDIR = '/home/grant/cdr-summaries';
my @SUMMARYattrs = ('Count', 'Duration', 'IntrastateCount', 'CarrierCost',
'Duration-Under7', 'Duration-Over180', 'Duration-Over2000', 'Duration-Over3600');

my $callType = $ARGV[0];
die "need a callType" unless defined $callType;

my %projRates; # $projRates{$pjid}

my $dbh;
my $r;

sub cdr_print {
	my $cdr = shift;
	print 
		$cdr->{'sbn_date'} . ',' .
		$cdr->{'sbn_time'} . ',' .
		$cdr->{'sbn_duration'} . ',' .
		$cdr->{'sbn_called'} . ',' .
		$cdr->{'sbn_cost'} . ',' .
		$cdr->{'sbn_i'} . ',' .
		$cdr->{'State Called'} .
		"\n"
}

sub cdr_dump {
	my $cdr = shift;

	for my $k (sort keys %$cdr) {
		my $val = $cdr->{$k};

		if (defined($val)) {
			printf '%-40s', $k;
			print ": $val\n";
		}
	}
}

sub make_summary_file {
	my $rdir = shift;
	my $counts = shift;
	my $phones = shift;

	my $characteristicDate; # used to sequence the dirs
	my $cnt = 0;

	# write out the daily amounts
	open SUMM, '>', "$rdir/summary.txt" or die "opening failed: $!";
	for my $d (keys %$counts) {

		if ($counts->{$d}{'Count'} > $cnt) {
			$cnt = $counts->{$d}{'Count'};
			$characteristicDate = $d;
		}
		print SUMM "$d";
		for my $t (@SUMMARYattrs) {
			my $val = $counts->{$d}{$t};
			$val = 0 unless defined($val);
			print SUMM " $val";
		}
		if ($counts->{$d}{'Duration'} > 0) {
			my $cave = (60 * $counts->{$d}{'CarrierCost'}) / $counts->{$d}{'Duration'};
			print SUMM " $cave";
		} else {
			print SUMM " 0.0";
		}
		print SUMM "\n";
	}
	close SUMM;

	open PHONES, '>', "$rdir/phones.txt" or die "open of phones failed: $!"; 
	for my $num (keys %$phones) {
		print PHONES "$num\t" . $phones->{$num} . "\n";
	}
	close PHONES;

	open JFILE, '>', "$rdir/summary.json" or die "opening failed: $!";
	print JFILE JSON::to_json($counts);
	close JFILE;

	system("echo $characteristicDate > $rdir/CharacteristicDate");
	system("touch $rdir/Completed");
}

sub csv_from_json {

	my $fname = shift;

	my $jtxt = `cat $fname`;
	my $counts = JSON::from_json($jtxt);

	my @colnames;
	my $rows;

	for my $k (keys %$counts) {
		if (! defined($rows)) {
			@colnames = keys %{$counts->{$k}};
		}

		$rows .= "$k";

		for my $col (@colnames) {
			my $val = $counts->{$k}{$col};
			$val = "" unless defined $val;
			$rows .= ",$val";
		}
		$rows .= "\n";
		
	}
	
	# headings...
	print "Date";
	map { print ",$_"; } @colnames;
	print "\n$rows";

}

sub qwest_Substr {
	my ($line, $start, $len) = @_;
	return substr($line, $start - 1, $len);
}

sub qwest_Parse {
	my $raw = shift;
	my %cdr;

	# from Wholesale-Layout-4_28_08_external.xls

	$cdr{'Call Service Type'}	= qwest_Substr($raw, 1, 2);
	$cdr{'component_group_cd'}	= qwest_Substr($raw, 3, 2);
	$cdr{'component_grp_val'}	= qwest_Substr($raw, 5, 24);
	$cdr{'product_acct_id'}	= qwest_Substr($raw, 29, 12);
	$cdr{'Customer Number'}	= qwest_Substr($raw, 41, 10);
	$cdr{'orig_dt'}			= qwest_Substr($raw, 51, 8);
	$cdr{'discn_dt'}			= qwest_Substr($raw, 59, 8);
	$cdr{'orig_time'}			= qwest_Substr($raw, 67, 6);
	$cdr{'discn_time'}			= qwest_Substr($raw, 73, 6);
	$cdr{'Call Duration Minutes'}	= qwest_Substr($raw, 79, 5);
	$cdr{'Call Duration Seconds'}	= qwest_Substr($raw, 84, 2);
	$cdr{'dialedno'}			= qwest_Substr($raw, 86, 15);
	$cdr{'calledno'}			= qwest_Substr($raw, 101, 15);
	$cdr{'ani'}				= qwest_Substr($raw, 116, 15);
	$cdr{'anstype'}			= qwest_Substr($raw, 131, 6);
	$cdr{'pindigs'}			= qwest_Substr($raw, 137, 4);
	$cdr{'infodig'}			= qwest_Substr($raw, 141, 2);
	$cdr{'Surcharge'}			= qwest_Substr($raw, 143, 1);
	$cdr{'compcode'}			= qwest_Substr($raw, 144, 6);
	$cdr{'predig'}				= qwest_Substr($raw, 150, 1);
	$cdr{'trtmtcd'}			= qwest_Substr($raw, 151, 6);
	$cdr{'orig_trunk_group_name'}	= qwest_Substr($raw, 157, 12);
	$cdr{'origmem'}			= qwest_Substr($raw, 169, 6);
	$cdr{'term_trunk_group_name'}	= qwest_Substr($raw, 175, 12);
	$cdr{'termmem'}			= qwest_Substr($raw, 187, 6);
	$cdr{'intra_lata_ind'}		= qwest_Substr($raw, 193, 1);
	$cdr{'Call Area'}			= qwest_Substr($raw, 194, 1);
	$cdr{'City Calling'}		= qwest_Substr($raw, 195, 10);
	$cdr{'State Calling'}		= qwest_Substr($raw, 205, 2);
	$cdr{'City Called'}		= qwest_Substr($raw, 207, 10);
	$cdr{'State Called'}		= qwest_Substr($raw, 217, 2);
	$cdr{'Rate Period'}		= qwest_Substr($raw, 219, 1);
	$cdr{'Terminating Country Code'}	= qwest_Substr($raw, 220, 4);
	$cdr{'Originating Country Code'}	= qwest_Substr($raw, 224, 4);
	$cdr{'PAC Codes'}			= qwest_Substr($raw, 228, 12);
	$cdr{'orig_pricing_npa'}	= qwest_Substr($raw, 240, 3);
	$cdr{'orig_pricing_nxx'}	= qwest_Substr($raw, 243, 3);
	$cdr{'term_pricing_npa'}	= qwest_Substr($raw, 246, 3);
	$cdr{'term_pricing_nxx'}	= qwest_Substr($raw, 249, 3);
	$cdr{'Authorization Code Full'}	= qwest_Substr($raw, 252, 14);
	$cdr{'univacc'}			= qwest_Substr($raw, 266, 10);
	$cdr{'prcmp_id'}			= qwest_Substr($raw, 276, 6);
	$cdr{'carrsel'}			= qwest_Substr($raw, 282, 1);
	$cdr{'cic'}				= qwest_Substr($raw, 283, 6);
	$cdr{'origlrn'}			= qwest_Substr($raw, 289, 10);
	$cdr{'portedno'}			= qwest_Substr($raw, 299, 10);
	$cdr{'lnpcheck'}			= qwest_Substr($raw, 309, 1);
	$cdr{'Originating IDDD City code'}	= qwest_Substr($raw, 310, 8);
	$cdr{'Terminating IDDD City code'}	= qwest_Substr($raw, 318, 8);
	$cdr{'Originating LATA'}		= qwest_Substr($raw, 326, 4);
	$cdr{'Terminating LATA'}		= qwest_Substr($raw, 330, 4);
	$cdr{'Class Type'}				= qwest_Substr($raw, 334, 2);
	$cdr{'Mexico Rate Step'}		= qwest_Substr($raw, 336, 2);
	$cdr{'Estimated Charge'}		= qwest_Substr($raw, 338, 6);
	$cdr{'Billing OCN'}			= qwest_Substr($raw, 344, 4);
	$cdr{'Orig_term_code'}			= qwest_Substr($raw, 348, 1);
	$cdr{'clgptyno'}				= qwest_Substr($raw, 349, 15);
	$cdr{'clgptyno_identifier'}	= qwest_Substr($raw, 364, 1);
	$cdr{'Orig OCN'}				= qwest_Substr($raw, 365, 4);
	$cdr{'Tern OCN'}				= qwest_Substr($raw, 369, 4);
	$cdr{'Unrounded Price'}		= qwest_Substr($raw, 373, 10);
	$cdr{'Rate per Minute'}		= qwest_Substr($raw, 383, 8);
	$cdr{'Finsid'}					= qwest_Substr($raw, 391, 6);
	$cdr{'Final trunk group name'}	= qwest_Substr($raw, 397, 12);
	$cdr{'Originating CLLI'}		= qwest_Substr($raw, 409, 11);
	$cdr{'Terminating CLLI'}		= qwest_Substr($raw, 420, 11);
	$cdr{'CLGNOLRN'}				= qwest_Substr($raw, 431, 10);
	$cdr{'CLGLRNID'}				= qwest_Substr($raw, 441, 1);
	$cdr{'Sequence Number'}		= qwest_Substr($raw, 442, 10);
	$cdr{'carriage_return'}		= qwest_Substr($raw, 409, 1);

	# sbn standard fields
	$cdr{'sbn_date'} = $cdr{'discn_dt'};
	$cdr{'sbn_time'} = $cdr{'discn_time'}; # end of call
	$cdr{'sbn_time'} =~ tr/0-9//cd;
	$cdr{'sbn_duration'} = 60 * $cdr{'Call Duration Minutes'} + $cdr{'Call Duration Seconds'};
	$cdr{'sbn_called'} = $cdr{'dialedno'};
	$cdr{'sbn_called'} =~ tr/0-9//cd; # because they have trailing spaces
	$cdr{'sbn_origin'} = $cdr{'ani'};
	my $qrate = substr($cdr{'Rate per Minute'},0,2) . "." . substr($cdr{'Rate per Minute'},2,12);
	$cdr{'sbn_cost'} = $cdr{'sbn_duration'} * $qrate / 60;
	$cdr{'sbn_carrier_rate'} = $qrate;
	$cdr{'sbn_i'} = ($cdr{'Call Area'} == 1) ? 'intra' : 'inter';

	# verify the rate charged
	my $rl_called = $r->lookup_number($cdr{'sbn_called'});
	my $rRate = $rl_called->{'Rates'}{'A'};
	if (defined($rRate)) {
		my $cost = ($rRate * $cdr{'sbn_duration'}) / 60;

		if (abs($rRate - $qrate) > 0.001) {
			#printf "looked up rate: %0.8f\n", $rRate;
			#cdr_dump(\%cdr);
			#exit;
		}
	}

	return \%cdr;
}


sub OLD_qwest_Parse {
	my $raw = shift;
	my %cdr;

	# from Extraction_Full_Daily_Layout_02-28-03(1)
	$cdr{'orig_bill_file_id'} 	= qwest_Substr($raw, 1, 11);
	$cdr{'seqnum'} 				= qwest_Substr($raw, 12, 11);
	$cdr{'customer_acct_id'} 	= qwest_Substr($raw, 23, 11);
	$cdr{'product_acct_id'} 	= qwest_Substr($raw, 34, 11);
	$cdr{'product_id'} 			= qwest_Substr($raw, 45, 6);
	$cdr{'prcmp_id'} 			= qwest_Substr($raw, 51, 6);
	$cdr{'component_group_cd'}	= qwest_Substr($raw, 57, 2);
	$cdr{'component_grp_val'} 	= qwest_Substr($raw, 59, 24);
	$cdr{'access_method_id'} 	= qwest_Substr($raw, 83, 6);
	$cdr{'billing_cycle_id'} 	= qwest_Substr($raw, 89, 6);
	$cdr{'aos_ind'} 			= qwest_Substr($raw, 95, 6);
	$cdr{'discn_dt'} 			= qwest_Substr($raw, 101, 8);
	$cdr{'discn_time'} 			= qwest_Substr($raw, 109, 6);
	$cdr{'orig_dt'} 			= qwest_Substr($raw, 115, 8);
	$cdr{'orig_time'} 			= qwest_Substr($raw, 123, 6);
	$cdr{'calldur'} 			= qwest_Substr($raw, 129, 11);
	$cdr{'adjusted_call_dur'} 	= qwest_Substr($raw, 140, 11);
	$cdr{'dialedno'} 			= qwest_Substr($raw, 151, 15);
	$cdr{'calledno'} 			= qwest_Substr($raw, 166, 15);
	$cdr{'ani'} 				= qwest_Substr($raw, 181, 15);
	$cdr{'clgptyno'} 			= qwest_Substr($raw, 196, 15);
	$cdr{'intra_state_ind'} 	= qwest_Substr($raw, 211, 1);
	$cdr{'intra_lata_ind'} 		= qwest_Substr($raw, 212, 1);
	$cdr{'orig_country_cd'} 	= qwest_Substr($raw, 213, 3);
	$cdr{'term_country_cd'} 	= qwest_Substr($raw, 216, 3);
	$cdr{'orig_iddd_city_cd'} 	= qwest_Substr($raw, 219, 11);
	$cdr{'term_iddd_city_cd'} 	= qwest_Substr($raw, 230, 11);
	$cdr{'orig_pricing_npa'} 	= qwest_Substr($raw, 241, 3);
	$cdr{'orig_pricing_nxx'} 	= qwest_Substr($raw, 244, 3);
	$cdr{'orig_pricing_line'} 	= qwest_Substr($raw, 247, 4);
	$cdr{'term_pricing_npa'} 	= qwest_Substr($raw, 251, 3);
	$cdr{'term_pricing_nxx'} 	= qwest_Substr($raw, 254, 3);
	$cdr{'term_pricing_line'} 	= qwest_Substr($raw, 257, 4);
	$cdr{'acctcd'} 				= qwest_Substr($raw, 261, 12);
	$cdr{'acctcd_val'} 			= qwest_Substr($raw, 273, 1);
	$cdr{'acctcd_len'} 			= qwest_Substr($raw, 274, 1);
	$cdr{'univacc'} 			= qwest_Substr($raw, 275, 10);
	$cdr{'carrsel'} 			= qwest_Substr($raw, 285, 1);
	$cdr{'rltcdr'} 				= qwest_Substr($raw, 286, 1);
	$cdr{'cic'} 				= qwest_Substr($raw, 287, 6);
	$cdr{'predig'} 				= qwest_Substr($raw, 293, 1);
	$cdr{'cnpredig'} 			= qwest_Substr($raw, 294, 1);
	$cdr{'pindigs'} 			= qwest_Substr($raw, 295, 4);
	$cdr{'infodig'} 			= qwest_Substr($raw, 299, 2);
	$cdr{'opchoice'} 			= qwest_Substr($raw, 301, 6);
	$cdr{'inv_service_id'} 		= qwest_Substr($raw, 307, 1);
	$cdr{'qos'} 				= qwest_Substr($raw, 308, 1);
	$cdr{'event_group_id'} 		= qwest_Substr($raw, 309, 11);
	$cdr{'swid'} 				= qwest_Substr($raw, 320, 6);
	$cdr{'origgrp'} 			= qwest_Substr($raw, 326, 6);
	$cdr{'origmem'} 			= qwest_Substr($raw, 332, 6);
	$cdr{'termgrp'} 			= qwest_Substr($raw, 338, 6);
	$cdr{'termmem'} 			= qwest_Substr($raw, 344, 6);
	$cdr{'finsid'} 				= qwest_Substr($raw, 350, 6);
	$cdr{'fintkgrp'} 			= qwest_Substr($raw, 356, 6);
	$cdr{'fintkmem'} 			= qwest_Substr($raw, 362, 6);
	$cdr{'orig_term_cd'} 		= qwest_Substr($raw, 368, 1);
	$cdr{'clgnolrn'} 			= qwest_Substr($raw, 369, 10);
	$cdr{'portedno'} 			= qwest_Substr($raw, 379, 10);
	$cdr{'lnpcheck'} 			= qwest_Substr($raw, 389, 1);
	$cdr{'dto_ind'} 			= qwest_Substr($raw, 390, 1);
	$cdr{'cainct'} 				= qwest_Substr($raw, 391, 1);
	$cdr{'termpvn'} 			= qwest_Substr($raw, 392, 15);
	$cdr{'call_type_cd'} 		= qwest_Substr($raw, 407, 1);
	$cdr{'compcode'} 			= qwest_Substr($raw, 408, 6);
	$cdr{'anstype'} 			= qwest_Substr($raw, 414, 6);
	$cdr{'qual_answer_type'} 	= qwest_Substr($raw, 420, 6);
	$cdr{'billnum'} 			= qwest_Substr($raw, 426, 24);
	$cdr{'trtmtcd'} 			= qwest_Substr($raw, 450, 6);
	$cdr{'rproc_bill_file_id'}	= qwest_Substr($raw, 456, 11);
	$cdr{'orig_state_cd'} 		= qwest_Substr($raw, 467, 2);
	$cdr{'orig_city_cd'} 		= qwest_Substr($raw, 469, 4);
	$cdr{'term_state_cd'} 		= qwest_Substr($raw, 473, 2);
	$cdr{'term_city_cd'} 		= qwest_Substr($raw, 475, 4);
	$cdr{'swless_orig_amt'} 	= qwest_Substr($raw, 479, 11);
	$cdr{'suspn_cd'} 			= qwest_Substr($raw, 490, 11);
	$cdr{'anisuff'} 			= qwest_Substr($raw, 501, 6);
	$cdr{'swless_orig_src'} 	= qwest_Substr($raw, 507, 2);
	$cdr{'origoprt'} 			= qwest_Substr($raw, 509, 6);
	$cdr{'opart'} 				= qwest_Substr($raw, 515, 6);
	$cdr{'tpart'} 				= qwest_Substr($raw, 521, 6);
	$cdr{'adin'} 				= qwest_Substr($raw, 527, 2);
	$cdr{'disctype'} 			= qwest_Substr($raw, 529, 6);
	$cdr{'cosove'} 				= qwest_Substr($raw, 535, 6);
	$cdr{'billable_cd'} 		= qwest_Substr($raw, 541, 1);
	$cdr{'origpvn'} 			= qwest_Substr($raw, 542, 15);
	$cdr{'tax_geocode'} 		= qwest_Substr($raw, 557, 12);
	$cdr{'tax_category_cd'} 	= qwest_Substr($raw, 569, 6);
	$cdr{'tax_service_cd'} 		= qwest_Substr($raw, 575, 6);
	$cdr{'dnis'} 				= qwest_Substr($raw, 581, 15);
	$cdr{'iddd_ind'} 			= qwest_Substr($raw, 596, 1);
	$cdr{'orig_trunk_usage_ind'} 	= qwest_Substr($raw, 597, 6);
	$cdr{'term_trunk_usage_ind'} 	= qwest_Substr($raw, 603, 6);
	$cdr{'final_trunk_usage_ind'} 	= qwest_Substr($raw, 609, 6);
	$cdr{'orig_trunk_time_bias_ind'}= qwest_Substr($raw, 615, 6);
	$cdr{'orig_trunk_type'} 		= qwest_Substr($raw, 621, 3);
	$cdr{'term_trunk_type'} 		= qwest_Substr($raw, 624, 3);
	$cdr{'final_trunk_type'} 		= qwest_Substr($raw, 627, 3);
	$cdr{'orig_trunk_group_name'} 	= qwest_Substr($raw, 630, 12);
	$cdr{'term_trunk_group_name'} 	= qwest_Substr($raw, 642, 12);
	$cdr{'final_trunk_group_name'} 	= qwest_Substr($raw, 654, 12);
	$cdr{'time_chng'} 			= qwest_Substr($raw, 666, 1);
	$cdr{'origlrn'} 			= qwest_Substr($raw, 667, 10);
	$cdr{'clglrnid'} 			= qwest_Substr($raw, 677, 1);
	$cdr{'filler_22'} 			= qwest_Substr($raw, 678, 22);
	$cdr{'carriage_return'} 	= qwest_Substr($raw, 700, 1);

	# sbn standard fields
	$cdr{'sbn_date'} = $cdr{'orig_dt'};
	$cdr{'sbn_time'} = $cdr{'orig_time'}; # TODO needs to be end of call
	$cdr{'sbn_time'} =~ tr/0-9//cd;
	$cdr{'sbn_duration'} = $cdr{'calldur'}; # TODO needs to be rounded
	$cdr{'sbn_called'} = $cdr{'dialedno'};
	$cdr{'sbn_origin'} = $cdr{'billnum'};
	$cdr{'sbn_cost'} = 0.00;
	$cdr{'sbn_i'} = ($cdr{'intra_state_ind'} == 1) ? 'intra' : 'inter';

	return \%cdr;
}

sub gblx_Substr {
	my ($line, $start, $end) = @_;
	my $len = $end - $start + 1;
	my $rc;
	eval { 
		$rc = substr($line, $start - 1, $len);
	};

	if ($@) {
		print "\nFailed to parse [$start, $end]:\n$line\n";
		die $@;
	}

	return $rc;
}

sub gblx_Parse {
	my $raw = shift;
	my %cdr;

	# global crossing file names: 0899584555_xxx.zip
	# where xxx is a sequence number
	

	$cdr{'Customer Number'} = gblx_Substr($raw, 1, 10);
	$cdr{'Accounting Code'} = gblx_Substr($raw, 11, 18);
	$cdr{'Originating City'} = gblx_Substr($raw, 19, 28);
	$cdr{'Originating State'} = gblx_Substr($raw, 29, 30);
	$cdr{'Originating LATA'} = gblx_Substr($raw, 31, 33);
	# Originating LATA-OCN are not useful for an npanxx mapping
	$cdr{'Call Date'} = gblx_Substr($raw, 34, 41);
	$cdr{'Call Time'} = gblx_Substr($raw, 42, 47);
	$cdr{'Time of Day '} = gblx_Substr($raw, 48, 48);
	$cdr{'Terminating Number'} = gblx_Substr($raw, 49, 58);
	$cdr{'CDR Type'} = gblx_Substr($raw, 59, 62);
	$cdr{'Filler'} = gblx_Substr($raw, 63, 63);
	$cdr{'Internal Use 1'} = gblx_Substr($raw, 64, 65);
	$cdr{'Terminating City'} = gblx_Substr($raw, 66, 75);
	$cdr{'Terminating State'} = gblx_Substr($raw, 76, 77);
	$cdr{'Terminating LATA'} = gblx_Substr($raw, 78, 80);
	$cdr{'Billable Duration'} = gblx_Substr($raw, 81, 89);
	$cdr{'Seconds or Minutes Flag'} = gblx_Substr($raw, 90, 90);
	$cdr{'Number of Decimals in Revenue'} = gblx_Substr($raw, 91, 92);
	$cdr{'Currency Code'} = gblx_Substr($raw, 93, 97);
	$cdr{'Originating Number'} = gblx_Substr($raw, 98, 107);
	$cdr{'Mexico Rate Zone'} = gblx_Substr($raw, 108, 108);
	$cdr{'Filler'} = gblx_Substr($raw, 109, 109);
	$cdr{'Terminating Country Code'} = gblx_Substr($raw, 110, 114);
	$cdr{'Originating Country Code'} = gblx_Substr($raw, 115, 119);
	$cdr{'Bill-to-Number'} = gblx_Substr($raw, 120, 135);
	$cdr{'Access Type'} = gblx_Substr($raw, 136, 136);
	$cdr{'Travel Type'} = gblx_Substr($raw, 137, 137);
	$cdr{'Third Party Number'} = gblx_Substr($raw, 138, 147);
	$cdr{'CIC'} = gblx_Substr($raw, 148, 152);
	$cdr{'Filler'} = gblx_Substr($raw, 153, 154);
	$cdr{'Dedicated Toll-free Indicator'} = gblx_Substr($raw, 155, 155);
	$cdr{'Operator Assist Indicator'} = gblx_Substr($raw, 156, 156);
	$cdr{'Dial Plan'} = gblx_Substr($raw, 157, 157);
	$cdr{'Info Digits'} = gblx_Substr($raw, 158, 159);
	$cdr{'Payphone Surcharge Indicator'} = gblx_Substr($raw, 160, 160);
	$cdr{'Originating OCN'} = gblx_Substr($raw, 161, 165);
	$cdr{'Terminating OCN'} = gblx_Substr($raw, 166, 170);
	$cdr{'Revenue'} = gblx_Substr($raw, 171, 188);
	$cdr{'Transport Flag'} = gblx_Substr($raw, 189, 189);
	$cdr{'Least Cost Routing Flag'} = gblx_Substr($raw, 190, 190);
	$cdr{'Resell Chassis'} = gblx_Substr($raw, 191, 192);
	$cdr{'Resell-Slot-Card'} = gblx_Substr($raw, 193, 195);
# records are actually only 203 wide on older formats  
# since these are not actually used we comment them out
#	$cdr{'LRN'} = gblx_Substr($raw, 196, 205);
#	$cdr{'LRN Flag'} = gblx_Substr($raw, 206, 206);
#	$cdr{'JIP '} = gblx_Substr($raw, 207, 212);
#	$cdr{'UNE Flag'} = gblx_Substr($raw, 213, 213);
#	$cdr{'Filler'} = gblx_Substr($raw, 214, 250);

	# sbn standard fields
	$cdr{'sbn_date'} = $cdr{'Call Date'};
	my $ct = $cdr{'Call Time'}; # TODO needs to be end of call
	$ct =~ tr/0-9//cd;
	if ($ct =~ /(\d\d)(\d\d)(\d\d)/) {
		my $h = $1 + 3;
		$h = 23 if $h > 23;
		$cdr{'sbn_time'} = "$h$2$3";
	} else {
		warn "$ct has unexpected time format";
		$cdr{'sbn_time'} = $ct;
	}

	$cdr{'sbn_duration'} = 1 * $cdr{'Billable Duration'}; 
	$cdr{'sbn_called'} = $cdr{'Terminating Number'};
	$cdr{'sbn_origin'} = $cdr{'Bill-to-Number'};
	$cdr{'sbn_i'} = ($cdr{'Terminating State'} eq $cdr{'Originating State'}) ? 'intra' : 'inter';

	my $dec = -$cdr{'Number of Decimals in Revenue'}; # NB see the minus
	my $rev = $cdr{'Revenue'};
	$cdr{'sbn_cost'} = $rev * (10**$dec);
	$cdr{'sbn_carrier_rate'} = (60 * $cdr{'sbn_cost'}) / $cdr{'sbn_duration'};

	return \%cdr;
}

sub bbcom_Parse {
	my $raw = shift;
	my %cdr;

	my @vals = split(/;/, $raw);
	$cdr{'Call Id'}					= $vals[0];
	$cdr{'Split Id'}				= $vals[1];
	$cdr{'Circuit Id'}				= $vals[2];
	$cdr{'Date'}					= $vals[3];
	$cdr{'Destination'}				= $vals[4];
	$cdr{'Billing Telephone Number'}= $vals[5];
	$cdr{'City-State-Country'}		= $vals[6];
	$cdr{'Duration'}				= $vals[7];
	$cdr{'Price'}					= $vals[8];
	$cdr{'Dialed Number'}			= $vals[9];
	$cdr{'Product Type'}			= 1*$vals[10];

	# sbn standard fields
	my $d = $cdr{'Date'};
	if ($d =~ /(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})/) {
		$cdr{'sbn_date'} = "$1$2$3";
		$cdr{'sbn_time'} = "$4$5$6"; # TODO needs to be end of call
	} else {
		warn "cdr date does not parse: $raw";
		$cdr{'sbn_date'} = $d;
		$cdr{'sbn_time'} = '12:00:00';
	}
	$cdr{'sbn_duration'} = 1 * $cdr{'Duration'}; 
	$cdr{'sbn_origin'} = $cdr{'Billing Telephone Number'};
	$cdr{'sbn_called'} = $cdr{'Destination'};
	$cdr{'sbn_i'} = (($cdr{'Product Type'} == 41) || $cdr{'Product Type'} == 25 || $cdr{'Product Type'} == 24) ? 'inter' : 'intra';
	$cdr{'sbn_cost'} = $cdr{'Price'};
	$cdr{'sbn_carrier_rate'} = 60 * $cdr{'Price'} / $cdr{'Duration'};

	return \%cdr;
}

sub gblx_Read {
	my $fname = shift;
	my %counts;
	my %phones;

	my $rdir = results_needed($fname);
	return unless (defined($rdir)) && (-d $rdir);

	open CDR, '-|', "/usr/bin/unzip -p $fname" or die "unzip of $fname failed"; 
	my $fcount = 0;

	while (my $raw = <CDR>) {
		# skip header and trailer
		next if (substr($raw, 0, 1) eq 'H') || (substr($raw, 0, 1) eq 'T');

		my $cdr = gblx_Parse($raw);
		count_cdr('F',\%counts, $cdr, \$fcount, \%phones);
	} 

	close CDR;
	print "... $fcount cdrs read\n";
	
	make_summary_file($rdir,  \%counts, \%phones);

}

sub gblx_ReadRaw {

	# 2701 is the lowest with the correct, long format

	my $inlist = `find $LOCALDIR/gblx -name '*.zip' | sort`;
	while (length($inlist) > 0) {
		my $len = index($inlist, "\n");
		my $fname = substr($inlist, 0, $len);
		$inlist = substr($inlist, $len + 1);

		gblx_Read($fname);
	}
}

sub count_cdr {
	my $carrChar = shift;
	my $counts = shift;
	my $cdr = shift;
	my $fcount = shift;
	my $phones = shift;

	my $dur = $cdr->{'sbn_duration'};

	$counts->{$cdr->{'sbn_date'}}{'Count'}++;
	$counts->{$cdr->{'sbn_date'}}{'Duration'} += $dur;
	$counts->{$cdr->{'sbn_date'}}{'CarrierCost'} += $cdr->{'sbn_cost'};
	if ($cdr->{'sbn_i'} eq 'intra') {
		$counts->{$cdr->{'sbn_date'}}{'IntrastateCount'}++ 
	} else {
		$phones->{$cdr->{'sbn_called'}} = $cdr->{'sbn_carrier_rate'};
	}

	if ($dur > 3600) {
		$counts->{$cdr->{'sbn_date'}}{'Duration-Over3600'}++;
	} elsif ($dur > 2000) {
		$counts->{$cdr->{'sbn_date'}}{'Duration-Over2000'}++;
	} elsif ($dur > 180) {
		$counts->{$cdr->{'sbn_date'}}{'Duration-Over180'}++;
	} elsif ($dur < 7) {
		$counts->{$cdr->{'sbn_date'}}{'Duration-Under7'}++;
	}

	my $ac = substr($cdr->{'sbn_called'},0,3);
	if (($ac == 204) or ($ac == 289) or ($ac == 306) or ($ac == 403) or ($ac == 416) or ($ac == 418) or ($ac == 450) or ($ac == 506) or ($ac == 514) or ($ac == 519) or ($ac == 604) or ($ac == 613) or ($ac == 647) or ($ac == 705) or ($ac == 709) or ($ac == 778) or ($ac == 780) or ($ac == 807) or ($ac == 819) or ($ac == 867) or ($ac == 902) or ($ac == 905)) {
		# canada
		$counts->{$cdr->{'sbn_date'}}{'Canada'}++;
	}


	$$fcount++;
	if ($$fcount % 10000 == 0) {
		print ".";
		print ">\n" if ($$fcount % 1000000 == 0);
	}
}

sub results_needed {
	my $fname = shift;

	my $base = $fname; 
	$base =~ s/.home.grant.carrier-cdr.(.*)$/$1/;
	$base =~ tr/\//_/;
	my $rdir = "$RESULTSDIR/$base";
	
	if (-f "$rdir/Completed") {
		print "skipping $base, already done\n";
		return undef;
	} else {
		system("rm -rf $rdir");
		mkdir $rdir;
		print "reading $fname, summarizing into $rdir\n";
		return $rdir;
	}

}

sub qwest_Read {
	my $fname = shift;

	# each file gets summarized into $RESULTSDIR/<filename>/...
	my %counts;
	my %phones;

	my $rdir = results_needed($fname);
	return unless (defined($rdir)) && (-d $rdir);

	open CDR, '<', $fname or die "opening of $fname failed: $!"; 
	my $fcount = 0;

	while (my $raw = <CDR>) {
		my $cdr = qwest_Parse($raw);
		count_cdr('A', \%counts, $cdr, \$fcount, \%phones);
	} 

	close CDR;
	print "... $fcount cdrs read\n";
	
	make_summary_file($rdir, \%counts, \%phones);
}

sub qwest_ReadRaw {

	print "reading qwest\n";

	my $inlist = `find $LOCALDIR/qwest -name '*.txt' | sort`;
	while (length($inlist) > 0) {
		my $len = index($inlist, "\n");
		my $fname = substr($inlist, 0, $len);
		$inlist = substr($inlist, $len + 1);

		qwest_Read($fname);
	}
}

sub bbcom_Read {
	my $fname = shift;

	# each file gets summarized into $RESULTSDIR/<filename>/...
	my %counts;
	my %phones;
	my %audit;

	my $rdir = results_needed($fname);
	return unless (defined($rdir)) && (-d $rdir);

	open CDR, '<', $fname or die "opening cdr file: $!";
	my $fcount = 0;

	while (my $raw = <CDR>) {
		my $cdr = bbcom_Parse($raw);
		count_cdr('D', \%counts, $cdr, \$fcount, \%phones);

		# verify the invoice against our Rates
		my $nn = substr($cdr->{'sbn_called'},0,6);
		my $rl_called = $r->lookup_number($cdr->{'sbn_called'});
		my $cost = ($rl_called->{'Rates'}{'D'} * $cdr->{'sbn_duration'}) / 60;
		
		$audit{'Total Count'}++;
		$audit{'Total Secs'} += $cdr->{'sbn_duration'};
		$audit{'Total Carrier Cost'} += $cdr->{'sbn_cost'};
		$audit{'Total Our Calc Cost'} += $cost;

		if ($cdr->{'sbn_i'} eq 'intra') {
			$audit{'Intrastate Count'}++;
			$audit{'Intrastate Secs'} += $cdr->{'sbn_duration'};
			my $rl_origin = $r->lookup_number($cdr->{'sbn_origin'});
			if ($rl_origin->{'StateCode'} eq $rl_called->{'StateCode'}) {
				$audit{'Intrastate Agree Count'}++;
			} else {
				$audit{'Intrastate Disagree Count'}++;
			}
		} else {
			if ($cdr->{'sbn_cost'} == $cost) {
				$audit{'Exact Agreement Count'}++;
				$audit{'Exact Agreement Secs'} += $cdr->{'sbn_duration'};
				$audit{'Exact Agreement Cost'} += $cost;
			} elsif (abs($cdr->{'sbn_cost'} - $cost) < 0.0005) {
				$audit{'Near Agreement Count'}++;
				$audit{'Near Agreement Secs'} += $cdr->{'sbn_duration'};
				$audit{'Near Agreement Carrier Cost'} += $cdr->{'sbn_cost'};
				$audit{'Near Agreement Our Calc Cost'} += $cost;
			} else {
				$audit{'Disagreement Count'}++;
				$audit{'Disagreement Secs'} += $cdr->{'sbn_duration'};
				$audit{'Disagreement Carrier Cost'} += $cdr->{'sbn_cost'};
				$audit{'Disagreement Our Calc Cost'} += $cost;
				$audit{"$nn Count"}++;
			}
		}
	} 

	close CDR;
	print "   ... $fcount cdrs read\n";
	
	open AUDIT, '>', "$rdir/audit.txt" or die "open of audit failed: $!"; 
	for my $k (sort keys %audit) {
		my $v = $audit{$k};
		next if ($k =~ /^\d{6} Count/) && ($v < 3); # skip small fry

		my $pk = $k;
		if ($k =~ /(.*)Secs$/) {
			$pk = "$1Mins";
			$v = int($v/60);
		}
		print AUDIT "$pk:$v\n";
	}
	close AUDIT;

	make_summary_file($rdir, \%counts, \%phones);
}

sub bbcom_ReadRaw {

	print "reading bbcom\n";

	my $inlist = `find $LOCALDIR/bbcom -name '*.txt' | sort`;
	while (length($inlist) > 0) {
		my $len = index($inlist, "\n");
		my $fname = substr($inlist, 0, $len);
		$inlist = substr($inlist, $len + 1);

		bbcom_Read($fname);
	}
}

sub sbn_Read {
	my $DAY = shift;
	my $fday = substr($DAY,0,4) . '-' . substr($DAY,4,2) . '-' . substr($DAY,6,2);

	# each file gets summarized into $SBNRESULTSDIR/$DAY/...
	my $rdir = "$SBNRESULTSDIR/$DAY";
	if (-f "$rdir/Completed") {
		print "skipping $DAY, already done\n";
		return;
	} else {
		system("rm -rf $rdir");
		mkdir $rdir;
	}

	print "reading sbn cdrs for $DAY, summarizing into $rdir ...\n";
	my %dayStats;	# $dayStats{CARR|Total}{Count|Duration|...}
	
	foreach my $file (`find /dialer/projects -wholename "/dialer/projects/*/cdr/cdr-$fday.zip"`) {
		chomp $file;
		my $pjid = $file;
		$pjid =~ s/.*_(\d*)\/cdr\/cdr-\d\d\d\d-\d\d-\d\d\.zip/$1/;

		print "$fday:  project $pjid ...\n";

		if (! open(DATA, "unzip -p '$file'|")) {
			die "Failed to open $file: $!";
		}

		while (my $line=<DATA>) {
			my $cdr = DialerUtils::sbncdr_parser($line);

			die "unparsable cdr $line" unless defined ($cdr);

			# determine the project's rate if needed
			if (!defined($projRates{$pjid})) {
				# lookup the rate ...
				# ... retrieve the project record
				my $p = $dbh->selectrow_hashref("select * from 
					project where PJ_Number = $pjid limit 1");
				if (! defined($p->{'PJ_Number'})) {
					die "unable to fetch project for $pjid on $DAY";
				}

				# ... retrieve the customer record
				my $cnum = $p->{'PJ_CustNumber'};
				my $c = $dbh->selectrow_hashref("select * from
					customer where CO_Number = $cnum limit 1");
				if (! defined($c->{'CO_Number'})) {
					die "unable to fetch customer record for $pjid on $DAY" .
						" using customer number $cnum";
				}

				if ($c->{'CO_ResNumber'} == 1) {
					$projRates{$pjid} = $c->{'CO_Rate'};
				} else {
					# ... retrieve the reseller record
					my $rnum = $c->{'CO_ResNumber'};
					my $r = $dbh->selectrow_hashref("select * from
						reseller where RS_Number = $rnum limit 1");
					if (! defined($r->{'RS_Number'})) {
						die "unable to fetch reseller record for $pjid on $DAY" .
							" using reseller number $rnum";
					}
					$projRates{$pjid} = $r->{'RS_Rate'};
					my $df = $r->{'RS_DistribFactor'};
					if ((defined($df)) && ($df > 1)) {
						$projRates{$pjid} = $r->{'RS_Rate'} * $df;
					}
				}
			}

			# determine if it counts as a connect 
			my $conn = 1;
			if ($cdr->{'Dialer'} eq 'COLD') {
				$conn = 0 if ($cdr->{'Disposition'} eq 'AC');
				$conn = 0 if ($cdr->{'Disposition'} eq 'AS') &&
							 ($cdr->{'CallSetup'} ne 'Standby-OFF');
			}

			# billing/rating
			my $rdur = 0;
			if ($cdr->{'Duration'} > 0) {
				my $m = 0;
				if ($cdr->{'Duration'} % 6 > 0) {
					$m = 6 - ($cdr->{'Duration'} % 6);
				}
				$rdur = $cdr->{'Duration'} + $m;

				# determine the revenue
				my $sbnRevenue = ($rdur / 60) * $projRates{$pjid};

				# determine the cost from NpaNxx table
				my $rl = $r->lookup_number($cdr->{'CalledNumber'});
				my $sbnRate = $rl->{'Rates'}{$cdr->{'CarrierCode'}};
				my $sbnCost = 0;
				if (defined($sbnRate)) {
					$sbnCost = ($rdur / 60) * $sbnRate;
				}

				# store the "day" stats
				$dayStats{$cdr->{'CarrierCode'}}{'Connects'} += $conn;
				$dayStats{$cdr->{'CarrierCode'}}{'Duration'} += $rdur;
				$dayStats{$cdr->{'CarrierCode'}}{'Revenue'} += $sbnRevenue;
				$dayStats{$cdr->{'CarrierCode'}}{'Cost'} += $sbnCost;

				$dayStats{'TOTAL'}{'Connects'} += $conn;
				$dayStats{'TOTAL'}{'Duration'} += $rdur;
				$dayStats{'TOTAL'}{'Revenue'} += $sbnRevenue;
				$dayStats{'TOTAL'}{'Cost'} += $sbnCost;
			} else {
				# non-connect stats
				$dayStats{$cdr->{'CarrierCode'}}{'NonConnects'} += $conn;
				$dayStats{'TOTAL'}{'NonConnects'} += $conn;
			}

		}
		close(DATA);
	}

	# write the dayStats
	open OUT, '>', "$rdir/dayStats.json" or die "failed to open: $!";
	print OUT JSON::to_json(\%dayStats, {pretty => 1});
	close OUT;

	system("touch $rdir/Completed");

}

sub sbn_ReadRaw {

	print "reading sbn\n";

	my $now = DateTime->now(time_zone => 'America/New_York'); 
	my $dt  = DateTime->now(time_zone => 'America/New_York'); 
	$dt->subtract_duration(DateTime::Duration->new(weeks => 6)); 
	while (DateTime->compare($dt, $now) < 0) {
		sbn_Read($dt->ymd(''));
		$dt = $dt->add(days => 1);
	}

}

sub do_perc {
	my $val = shift;
	my $total = shift;

	$val = 0 unless defined $val;
	my $perc = '';
	if ((defined($total)) && ($total > 0)) {
		$perc = sprintf('%0.1f%%', 100 * $val / $total);
	}
	return "$val,$perc,";
}

sub sbn_summarize {

	my %ss; # spreadsheet  ss{'2009-01-01'}{Mins|Conns|Cost|
	# read the CarrierSummary.json file
	my $jtxt = `cat $SBNRESULTSDIR/CarrierSummary.json`;
	my $carrSumm = JSON::from_json($jtxt);

	my $now = DateTime->now(time_zone => 'America/New_York'); 
	my $nowstr = $now->ymd . ' ' . $now->hms;
	my $dt  = DateTime->new(year => 2009, month => 10, day => 1,
	  	time_zone  => 'America/New_York');

	my $bigcsv = 
		"Produced: $nowstr\n" . 
		"Date," . 
		'Mins-Qwest, Mins-GCNS, Mins-Gblx, Mins-MB, Mins-Mass, Mins-Mike,' .
		'Conns-Qwest, Conns-GCNS, Conns-Gblx, Conns-MB, Conns-Mass, Conns-Mike,' .
		'Cost-Qwest, Cost-GCNS, Cost-Gblx, Cost-MB, Cost-Mass, Cost-Mike' .
		"\n";

	while (DateTime->compare($dt, $now) < 0) {
		my $ymd = $dt->ymd('');
		my $sbndir = "$SBNRESULTSDIR/$ymd";
		if ( -d $sbndir ) {
			print "doing $sbndir\n";

			# Column: date
			$bigcsv .= "$ymd,";

			# read dayStats
			$jtxt = `cat $sbndir/dayStats.json`;
			my $dayStats = JSON::from_json($jtxt);

			# Columns: minutes
			for my $carr ('A', 'B', 'F', 'G', 'H', 'Z') { 
				my $dur = $dayStats->{$carr}{'Duration'};
				$dur = (defined($dur)) ? $dur /60 : 0;
				if ($carr eq 'F') {
					$dur = $dur / 1.04;
				} else {
					$dur = $dur / 1.07;
				}
				$bigcsv .= int($dur) . ',';
			}

			# Columns: connects
			for my $carr ('A', 'B', 'F', 'G', 'H', 'Z') { 
				my $conn = $dayStats->{$carr}{'Connects'};
				$conn = 0 unless defined($conn);
				$bigcsv .= int($conn) . ',';
			}

			# Columns: cost
			for my $carr ('A', 'B', 'F', 'G', 'H', 'Z') { 
				my $cost = $dayStats->{$carr}{'Cost'};
				$cost = 0 unless defined($cost);
				$bigcsv .= sprintf('%0.2f,', $cost);
			}

			$bigcsv .= "\n";
		}
		$dt = $dt->add(days => 1);
	}

	open OUT, '>', "/dialer/website/cdr-summary/cdr-summary.csv" or die "opening failed: $!";
	print OUT $bigcsv;
	close OUT;
}

sub accumulate {
	my $carrChar = shift;
	my $res = shift;
	my $rdir = shift;


	if (open SUMM, '<', "$rdir/summary.txt") {
		while (<SUMM>) {
			my @vals = split; # splits on whitespace by default
			my $key = $vals[0];
			my $i = 0;
			for my $t (@SUMMARYattrs) {
				$i++; 
				$res->{$key}{$t} += $vals[$i];
			}
		}
		close SUMM;
	} else {
		print "(missing summary.txt in $rdir)\n";
	}

}

sub make_phones {

	my $phload = "$RESULTSDIR/phones.load";
	unlink($phload) if -f $phload;

	print "making the phones table\n";

	# read all the result directories and the first date in summary.txt, also determine carrier char
	my $inlist = `find $RESULTSDIR -type d -wholename '*/results/*'`;
	my @dirs;
	while (length($inlist) > 0) {
		my $len = index($inlist, "\n");
		my $dirname = substr($inlist, 0, $len);
		$inlist = substr($inlist, $len + 1);

		# skip bbcom - we don't use phones for them
		next if $dirname =~ /bbcom/;

		# read the CharacteristicDate
		if (open CHARDT, '<', "$dirname/CharacteristicDate") {
			my $dt = <CHARDT>;
			close CHARDT;
			if ($dt =~ /^(20\d{6})/) {
				push @dirs, { DirName => $dirname, DirDate => $1 };
			} else {
				print "($dirname/CharacteristicDate does not have a parable date)\n";
			}
		} else {
			print "(missing CharacteristicDate in $dirname)\n";
		}
	}

	# sort the directories in date sequence
   	my @sorteddirs = sort { $a->{DirDate} <=> $b->{DirDate} } @dirs;
	my %carrIndex = ( 'gblx' => 0, 'qwes' => 1);

	my $acdr = 0;

	# break it up into multiple scans
	for (my $i = 0; $i < 10; $i++) {
		my $tcdr = 0;
		my $fcdr = 0;
		my $ucdr = 0;
		print "$i: ";
		my %phones; 
		for my $d (@sorteddirs) {
			my $dir = $d->{DirName};
			$dir =~ /.home.grant..*\/(.{4}).*/;
			my $carrIdx = $carrIndex{$1};
			die "$dir - cannot determine carrier" unless defined $carrIdx;

			open PHONES, '<', "$dir/phones.txt" or die "open of $dir/phones failed: $!"; 
			while (<PHONES>) {
				if (/(\d{9})(\d)\s*([\.0-9]*)\n/) {
					$tcdr++;
					next unless ($2 == $i);
					$fcdr++;
					my ($num, $rate) = ("$1$2", $3);
					$phones{$num}->[$carrIdx] = $rate;
				} else {
					die "unparsable $dir/phones.txt line: $_\n";
				}
			}
			close PHONES;

			print ".";
			# print $d->{DirDate} . ' ' . $d->{DirName} . "\n";
		}
		print " writing ... ";

		open PHLOAD, '>>', $phload or die "open of $phload failed: $!";
		for my $num (keys %phones) {
			print PHLOAD "$num\t";
			$ucdr++;
			$acdr++;

			for (my $k = 0; $k < 2; $k++) {
				if (defined($phones{$num}->[$k])) {
					print PHLOAD $phones{$num}->[$k] . "\t";
				} else {
					print PHLOAD "\\N\t";
				}
			}
			print PHLOAD "\n";
		}
		close PHLOAD;
		print "ok ($fcdr cdrs used out of $tcdr for run-$i, giving $ucdr unique phone numbers)\n";
	}
	print "we have $acdr total unique phone numbers\n";

	# load phones.load into phones - then rebuild index
	print "loading phones table\n";
	system("mv $phload /var/lib/mysql/sbn2/phones.tmp");
	my $sbn2 = DBI->connect("DBI:mysql:sbn2;host=localhost", 'root', 'sbntele') || die("Cannot Connect to database: $!");
	$sbn2->do("truncate table phones");
	$sbn2->do("alter table phones drop primary key");
	$sbn2->do("load data infile 'phones.tmp' into table phones (PH_Number, PH_CarrierF, PH_CarrierA)");
	my $res = $sbn2->selectrow_hashref("select count(*) as RowCount from phones");
	my $phcount = $res->{'RowCount'};
	print "phones has $phcount rows\n";
	$sbn2->do("alter table phones add primary key(PH_Number)");
	$sbn2->disconnect;
	system("mv /var/lib/mysql/sbn2/phones.tmp $phload");
}

sub summarize {

	my %summaries = ( 'gblx' => {}, 'qwest' => {}, 'bbcom' => {}); # eg: $summaries{gblx}{$date}

	print "accumulating...\n";
	my $ac = 0;

	# global crossing
	my $inlist = `find $RESULTSDIR -name 'gblx_*' -type d | sort`;
	while (length($inlist) > 0) {
		my $len = index($inlist, "\n");
		my $dirname = substr($inlist, 0, $len);
		$inlist = substr($inlist, $len + 1);

		$ac++;
		accumulate('F', $summaries{gblx}, $dirname);
	}
	print "accumulated $ac gblx directories\n";
	$ac = 0;

	# qwest
	$inlist = `find $RESULTSDIR -name 'qwest_*' -type d | sort`;
	while (length($inlist) > 0) {
		my $len = index($inlist, "\n");
		my $dirname = substr($inlist, 0, $len);
		$inlist = substr($inlist, $len + 1);

		$ac++;
		accumulate('A', $summaries{qwest}, $dirname);
	}
	print "accumulated $ac qwest directories\n";
	$ac = 0;

	# bbcom
	$inlist = `find $RESULTSDIR -name 'bbcom_*' -type d | sort`;
	while (length($inlist) > 0) {
		my $len = index($inlist, "\n");
		my $dirname = substr($inlist, 0, $len);
		$inlist = substr($inlist, $len + 1);

		$ac++;
		accumulate('D', $summaries{bbcom}, $dirname);
	}
	print "accumulated $ac bbcom directories\n";

	print "summarizing ...\n";

	# write out the big summary
	my $summf = "$RESULTSDIR/CarrierSummary.json";
	open SUMM, '>', $summf or die "opening $summf failed: $!";
	print SUMM JSON::to_json(\%summaries, {pretty => 1});
	close SUMM;
	system("scp $summf w0.sbndials.com:/home/grant/cdr-summaries/");
}


######################################################################

$r = initialize Rates(1);

if (( -d '/dialer/projects/_1/cdr' ) && ($callType eq 'worker0')) {
	# running on w0 so we are doing SBN cdrs
	$dbh = DialerUtils::db_connect();
	sbn_ReadRaw();
	sbn_summarize();
	$dbh->disconnect;
} else {
	if ($callType eq 'jrep') {
		csv_from_json($ARGV[1]);
	}

	qwest_ReadRaw() if ($callType eq 'qwest');
	bbcom_ReadRaw() if ($callType eq 'bbcom');
	gblx_ReadRaw() if ($callType eq 'gblx');

	summarize() if ($callType eq 'summary');
	make_phones() if ($callType eq 'phones');
}

