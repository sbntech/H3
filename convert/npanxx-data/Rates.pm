#!/usr/bin/perl

=pod

A ---> Qwest
B ---> GCNS City Voice
C ---> Selway
D ---> SWS (Smart World Solutions)
E ---> Platinum
F ---> Global Crossing
G ---> MBiz
H ---> Massive
I --->

interstate rates only

=cut

package Rates;

use strict;
use warnings FATAL => 'all';
use Text::CSV_XS;

our %NpaNxx; # hash: lata, ocn, A, B ...

my $DATADIR = '/home/grant/sbn-git/convert/npanxx-data';

# -----------------------------------------------------------------------------
sub load_canada_file {
	my $self = shift;

	my $oCanada;
	my $csv = Text::CSV_XS->new({ binary => 1 });
	my $count = 0;
	my %NpaNxx;

	open($oCanada, '<', "$DATADIR/Canadian-NPANXX.csv") or die "failed to open Canada file: $!";
	readline($oCanada); # read off the headers
	
	while (my $row = $csv->getline($oCanada)) {
		my ($NPA, $NXX, $OCN, $Company, $Status, $RateCenter) = @$row;
		$NpaNxx{"$NPA$NXX"} = $Company;
		$count++;
	}
	close($oCanada);

	print "Canada has $count prefixes\n" if $self->{Verbose};
	$self->{'CanadaNPANXX'} = \%NpaNxx;
}

# -----------------------------------------------------------------------------
sub load_rate_file {
	my $self = shift;
	my $path = shift;
	my $carrier = shift;
	my $char = shift;

	my $count = 0;
	my %NpaNxx;

	open(RF, '<', $path) or die "failed to open $path: $!";
	while (my $row = <RF>) {
		#npanxx,rate
		if ($row =~ /^(\d{3,6}),(.*)\s*$/) {
			$NpaNxx{$1} = $2;
			$count++;
		} else {
			die "Matching failure line $count: $row";
		}
	}
	close(RF);

	print "$carrier ($char) has rates for $count prefixes in $path\n" if $self->{Verbose};
	$self->{$carrier} = \%NpaNxx;
}


# -----------------------------------------------------------------------------
sub read_LATAOCN_file {
	my $self = shift;
	my $path = shift;
	my $char = shift;
	my $default = shift; # default interstate rate

	my %Xrates;

	open(RF, '<', $path) or die "failed to open $path: $!";
	while (<RF>) {
		#LATA,OCN,rate
		if (/^(\d*),([^,]*),([\.0-9]*)$/) {
			my ($lata, $ocn, $rate) = ($1,$2,$3);

			if (defined($Xrates{$lata}{$ocn})) {
				print "$char:  $lata-$ocn has mutiple rates\n";
			} else {
				$Xrates{$lata}{$ocn} = $rate;
			}
		} else {
			print "Matching failure of: $_";
		}
	}
	close(RF);

	for my $n (keys %NpaNxx) {
		my $h = $NpaNxx{$n};
		my ($lata, $ocn) = ($h->{lata}, $h->{ocn});

		my $rate = $default; 
		if ((defined($lata)) && (defined($ocn))) {
			if (defined($Xrates{$lata}{$ocn})) {
				$rate = $Xrates{$lata}{$ocn};
			}
		}
		$NpaNxx{$n}->{$char} = $rate;
	}
}

# -----------------------------------------------------------------------------
sub lookup_number {
	my $self = shift;
	my $number = shift;
	my $CustomerNumber = shift; # optional
	my $ResellerNumber = shift; # optional
	my $sbn2 = shift; # optional

	my $ac = substr($number,0,3);
	my $nn4 = substr($number,0,4);
	my $nn5 = substr($number,0,5);
	my $npanxx = substr($number,0,6);
	my @checklist = ( $npanxx, $nn5, $nn4, $ac );

	my $nxx = substr($number,3,3);
	my $block = substr($number,6,1);

	my $rh = {
		StateCode	=> 'XX',
		TimeZone	=> 0,
		Lata		=> 'UNKNOWN',
		Ocn			=> 'UNKNOWN',
		Type		=> 'UNKNOWN',
		Rates		=> {},
		Routable	=> 0,
		Footprint	=> 0,
		BestCarriers => '',
		AltCarriers => '',
		ScrubType	=> 'XR'
	};

	if ((defined($CustomerNumber)) && (defined($ResellerNumber)) &&
		($CustomerNumber > 0) && ($ResellerNumber > 1)) {

		if (($CustomerNumber == 11966) || # cleartalk
			($CustomerNumber == 12178) || # joey2
			($CustomerNumber == 13088) || # 7-31-09
			($CustomerNumber == 13832) || # newartist 6/3/2009
			($CustomerNumber == 15548) || # kend 19-Jan-2010
			($ResellerNumber ==   5) || #sam
			($ResellerNumber ==  75) || # doug
			($ResellerNumber ==  78) || # cleartalk2
			($ResellerNumber ==  88) || # cleartalk3
			($ResellerNumber ==  99) || # Moneymaker1 6-2-09
			($ResellerNumber == 111) || # rick
			($ResellerNumber == 116) || # caplin - Doug - 26 April 2010
			($ResellerNumber == 117) || # 6-22-09
			($ResellerNumber == 120) || # Mark2 7-32-09
			($ResellerNumber == 123) || # ibroadcastcheap 03-Dec-2009
			($ResellerNumber == 128)    # funguy1950 roy 20-Jan-2010
		   ) {
			$rh->{'Footprint'} = 1; # cheap USA
		}

		if (
			($ResellerNumber == 115) # Caplan-Canada 13-Apr-2009
		   ) {
			$rh->{'Footprint'} = 2; # Canada only
		}

	}

	if (
			($self->{'Exclusions'}{$npanxx}) ||
			($nxx eq '555') ||
			($nxx eq '911') ||
			($nxx eq '411') 
		) {
		return $rh;
	}

	# determine state code and time zone
	$rh->{'StateCode'} = $self->{'StateCode'}{$ac} if defined($self->{'StateCode'}{$ac});
	$rh->{'TimeZone'} = $self->{'TimeZone'}{$ac} if defined($self->{'TimeZone'}{$ac});

	if (defined($self->{'Telcodata'}{$npanxx})) {
		$rh->{'Lata'} = $self->{'Telcodata'}{$npanxx}[0];
		$rh->{'Ocn'}  = $self->{'Telcodata'}{$npanxx}[1];
	}

	if (($rh->{'StateCode'} eq 'HI') || ($rh->{'StateCode'} eq 'AK') || ($rh->{'StateCode'} eq 'XX')) {
		#        Hawaii                             Alaska                       Exotic     
	} elsif ($rh->{'StateCode'} eq 'XC') { # Canada

		if ($rh->{'Footprint'} != 2) {
			# Canada-only footprint scrubbing
			$rh->{'ScrubType'} = 'XF';
		} elsif (defined($self->{'CanadaNPANXX'}{$npanxx})) {
			$rh->{'Routable'} = 1;
			
			my $CAroutes = '';
			my $CAalts = '';

			# GCNS --- 
			$rh->{'Rates'}{'B'} = 0.017;
			$CAroutes .= 'B';

			# Selway (C)
			SELWAYPREFIX: for my $prefix (@checklist) {
				if (defined($self->{'Selway'}{$prefix})) {
					$rh->{'Rates'}{'C'} = $self->{'Selway'}{$prefix};
					$CAroutes .= 'C';
					last SELWAYPREFIX;
				}
			}

			# SWS - Smart Worlds Solutions (D) ---
			SWSPREFIX: for my $prefix (@checklist) {
				if (defined($self->{'SWS'}{$prefix})) {
					$rh->{'Rates'}{'D'} = $self->{'SWS'}{$prefix};
					if ($rh->{'Rates'}{'D'} < 0.01) {
						$CAroutes .= 'D';
					} else {
						$CAalts .= 'D';
					}
					last SWSPREFIX;
				}
			}

			# Platinum E --- 
			$rh->{'Rates'}{'E'} = 0.01; # not the real rate
			$CAroutes .= 'E'; 

			# Massive --- 
			$rh->{'Rates'}{'H'} = 0.0092;
			$CAroutes .= 'H';

			if (length($CAroutes) > 1) {
				$rh->{'BestCarriers'} = $CAroutes;
				$rh->{'AltCarriers'} = $CAalts;
				$rh->{'ScrubType'} = undef;
			}
		}
	} else { # U.S.A. 

		# qwest ---
		$rh->{'Rates'}{'A'} = 0.015; # Qwest default interstate rate
		if (defined($self->{'Qwest-pumping'}{$rh->{'Lata'}}{$rh->{'Ocn'}})) {
			$rh->{'Rates'}{'A'} = 0.3; # traffic pumping rate
		} elsif (defined($self->{'Qwest'}{$rh->{'Lata'}}{$rh->{'Ocn'}})) {
			$rh->{'Rates'}{'A'} = $self->{'Qwest'}{$rh->{'Lata'}}{$rh->{'Ocn'}};
			$rh->{'Routable'} = 1;
		}

		# global crossing ---
		$rh->{'Rates'}{'F'} = 0.05; # Global Crossing default interstate rate
		if (defined($self->{'GBLX'}{$rh->{'Lata'}}{$rh->{'Ocn'}})) {
			$rh->{'Rates'}{'F'} = $self->{'GBLX'}{$rh->{'Lata'}}{$rh->{'Ocn'}};
			$rh->{'Routable'} = 1;
		}

		# GCNS ---
		if (defined($self->{'GCNS'}{$npanxx})) {
			$rh->{'Rates'}{'B'} = $self->{'GCNS'}{$npanxx};
			$rh->{'Routable'} = 1;
		}

		# Monky Biz ---
		$rh->{'Rates'}{'G'} = 0.03; # default interstate rate
		if (defined($self->{'MBiz'}{$npanxx})) {
			$rh->{'Rates'}{'G'} = $self->{'MBiz'}{$npanxx};
			$rh->{'Routable'} = 1;
		}

		if (defined($sbn2)) {
			# determine carriers
			
			my @CARRIERS = ('A', 'F', 'G'); # new carrier needs to be added here
			my %BEST = ( 
				'A' => 0.0095,	# Qwest
				'F' => 0.0095,	# gblx
				'G' => 0.009,	# Mbiz 
				); 
			my $ALT = 0.03;
			my $BestCarriers = '';
			my $AltCarriers = '';

			my $phones = $sbn2->selectrow_hashref("select * from phones where PH_Number = '$number' limit 1");

			# determine BestCarriers and the cheapest
			my %bests;
			my %carrRates; # $carrRates{'A'} = 0.001  and undef means no rate
			my $cheapest = 10.0;
			my $cheapestCarr;
			for my $carr (@CARRIERS) { 
				if (($carr eq 'A') || ($carr eq 'F')) {	# carriers that use the phones table
					if ((defined($phones->{"PH_Carrier$carr"})) && ($phones->{"PH_Carrier$carr"} > 0)) {
						# we use the 'phones' rate
						$carrRates{$carr} = $phones->{"PH_Carrier$carr"};
					}
				}

				if ((!defined($carrRates{$carr})) && (defined($rh->{'Rates'}{$carr})) && ($rh->{'Rates'}{$carr} > 0)) {
					# we use our lookup
					$carrRates{$carr} = $rh->{'Rates'}{$carr};
				}

				if (defined($carrRates{$carr})) {
					if (($carrRates{$carr} < $cheapest) && ($carr ne 'G')) {
						$cheapest = $carrRates{$carr};
						$cheapestCarr = $carr;
					}

					if ($carrRates{$carr} < $BEST{$carr}) {
						$bests{$carr} = 1;
					}
				}

			}

			if (($rh->{'Routable'} == 1) && (defined($cheapestCarr))) {

				$bests{$cheapestCarr} = 1;

				if ($cheapest > 0.03) {
					# woa! scrub this expensive thing
					$rh->{'ScrubType'} = 'XE';
				} elsif ($rh->{'Footprint'} == 2) {
					# Canada only scrubbing
					$rh->{'ScrubType'} = 'XF';
				} elsif (($rh->{'Footprint'} == 1) && ($cheapest > 0.008)) {
					# limited footprint scrubbing
					$rh->{'ScrubType'} = 'XF';
				} else {
					# determine AltCarriers
					my %alternates;
					for my $carr (@CARRIERS) {
						next if defined($bests{$carr});
						if ((defined($carrRates{$carr})) && ($carrRates{$carr} < $ALT)) {
								$alternates{$carr} = 1;
						}
					}

					map { $BestCarriers .= $_; } sort keys %bests;
					map { $AltCarriers .= $_; } sort keys %alternates;

					$rh->{'BestCarriers'} = $BestCarriers;
					$rh->{'AltCarriers'} = $AltCarriers;
					$rh->{'ScrubType'} = undef;
				}
			}
		}
	}

	# OCN type ---
	if (defined($self->{'OCN-Type'}{$rh->{'Ocn'}})) {
		$rh->{'Type'} = $self->{'OCN-Type'}{$rh->{'Ocn'}};
	}

	return $rh;
}

# -----------------------------------------------------------------------------
sub load_telcodata {
	my $self = shift;

	my %OCNtype;
	my %Nanpa;

	my $fn = "$DATADIR/nanpa-sorta-nothousands.csv";
	my $count = 0;
	my $nncnt = 0;
	open(LATAOCN, '<', $fn) or die "Cannot open $fn: $!";
	my $heading = <LATAOCN>; # chomp the heading line
	while (<LATAOCN>) {
		$count++;
		if (/^"(\d{3})","(\d{3})","([^"]*)","([^"]*)","([^"]*)","([^"]*)","([^"]*)","([^"]*)","([^"]*)","([^"]*)","([^"]*)","([^"]*)"\r/) {
			my ($nn,$state,$company,$ocn,$ratectr,$clli,$assdt,$ptype,$swname,$swtyp,$lata) = 
				("$1$2",$3,$4,$5,$6,$7,$8,$9,$10,$11,$12);

			$Nanpa{$nn} = [$lata, $ocn]; 
			$nncnt++;

			$ocn =~ s/^0*(\d*)$/$1/; # remove leading zeroes
			if ((defined($OCNtype{$ocn})) && ($OCNtype{$ocn} ne $ptype)) {
				print "OCN $ocn is given conflicting types: $ptype and " .
					$OCNtype{$ocn} . "\n";
			} else {
				$OCNtype{$ocn} = $ptype;
			}
		} else {
			print "Matching failure of: $_ ";
		}
	}
	close(LATAOCN);
	
	my $ocncnt = 0;
	my $ocnunk = 0;
	for my $k (keys %OCNtype) {
		$ocncnt++;
		if ($OCNtype{$k} eq '') {
			$ocnunk ++;
			$OCNtype{$k} = 'MISSING' 
		}
		if (($OCNtype{$k} eq 'WIRELESS') || ($OCNtype{$k} eq 'PCS') || ($OCNtype{$k} eq 'W RESELLER')) {
			$OCNtype{$k} = 'MOBILE';
		}
	}

	$self->{'OCN-Type'} = \%OCNtype;
	$self->{'Telcodata'} = \%Nanpa;

	print "$count records read, yielding $ocncnt OCNs of which $ocnunk where missing a type. (from $nncnt records) in $fn\n" if $self->{Verbose};
}

# -----------------------------------------------------------------------------
sub load_areacodes {
	my $self = shift;

	my %TimeZone; # $TimeZone{'949'}
	my %StateCode; # as in $StateCode{$areacode}

	# XC ==> Canada, XX ==> other exotics
	my $count = 0;
	open(TZFILE, '<', "$DATADIR/areacode-timezone.txt") or die "Cannot open timezone file: $!";
	while (<TZFILE>) {
		if (/^(\d{3}) (\d*) (..) (.*)$/) {
			my ($areacode, $tz, $stcode, $desc) = ($1, $2, $3, $4);
			$TimeZone{$areacode} = $tz;
			$StateCode{$areacode} = $stcode;
			$count++;
		} else {
			chomp;
			print "Parse Error: $_ not matched\n";
		}
	}
	close(TZFILE);

	$self->{'TimeZone'} = \%TimeZone;
	$self->{'StateCode'} = \%StateCode;

	print "$count areacodes with timezone\n" if $self->{Verbose};
}

# -----------------------------------------------------------------------------
sub load_qwest {
	my $self = shift;

	# Qwest rates - Carrier A
	my %qwest;

	open(RF, '<', "$DATADIR/QWEST-Interstate.csv") or die "failed to open: $!";
	while (<RF>) {
		
		#LATA,OCN,rate
		if (/^(\d*),([^,]*),([\.0-9]*)$/) {
			my ($lata, $ocn, $rate) = ($1,$2,$3);

			if (defined($qwest{$lata}{$ocn})) {
				print "qwest:  $lata-$ocn has mutiple rates\n";
			} else {
				$qwest{$lata}{$ocn} = $rate;
			}
		} else {
			print "Matching failure of: $_";
		}
	}
	close(RF);

	my %qwest_pumping; # as in $qwest_pumping{$lata}{$ocn}
	open(RF, '<', "$DATADIR/QWEST-traffic-pumping.csv") or die "failed to open: $!";
	while (<RF>) {
		#OCN,LATA
		if (/^([^,]*),([^,]*)\n$/) {
			my ($ocn, $lata) = ($1,$2);
			$qwest_pumping{$lata}{$ocn} = 1;
		} else {
			print "qwest pumping: $_ not matched\n";
		}
	}
	close(RF);

	$self->{'Qwest'} = \%qwest;
	$self->{'Qwest-pumping'} = \%qwest_pumping;

	print "Qwest rates loaded\n" if $self->{Verbose};
}

# -----------------------------------------------------------------------------
sub load_gblx {
	my $self = shift;

	# Global Crossing rates - Carrier F
	my %Frates; # as in $Frates{lata}{ocn}
	my $filename = "$DATADIR/global-crossing-inter.csv";

	open(RF, '<', $filename) or die "$filename failed to open: $!";
	while (<RF>) {
		# LATA,OCN,RATE
		if (/^([^,]*),([^,]*),([^,]*)$/) {
			my ($lata, $ocn, $rate) = ($1,$2,1.0*$3);
			die "strange LATA format $lata" unless ($lata =~ /\d\d\d/);
			die "strange OCN format $ocn" unless ($ocn =~ /[0-9ABCDEF]{4}/);
			die "strange rate $rate" unless ($rate > 0.0001) and ($rate < 0.3);
			if (defined($Frates{$lata}{$ocn})) {
				print "$filename:  $lata-$ocn has mutiple rates\n";
			} else {
				$Frates{$lata}{$ocn} = $rate;
			}
		} else {
			print "$filename: $_ not matched\n";
		}
	}
	close(RF);
	$self->{'GBLX'} = \%Frates;
	print "Loaded Global Crossing rates\n" if $self->{Verbose};
}

sub initialize {
	my $class = shift;
	my $verbose = shift;
	my $self = { Verbose => $verbose };
	bless $self;

	print "Rates initializing verbosely\n" if $self->{Verbose};

	$self->load_canada_file;
	$self->load_areacodes;
	$self->load_telcodata;
	$self->load_qwest;
	$self->load_gblx;
	$self->load_rate_file("$DATADIR/monkey-biz.csv", 'MBiz', 'G');
	$self->load_rate_file("$DATADIR/Smart-World-Solutions-CANADA.csv", 'SWS', 'D');
	$self->load_rate_file("$DATADIR/Selway.csv", 'Selway', 'C');
	$self->load_rate_file("$DATADIR/gcns.csv", 'GCNS', 'B');

	$self->{'Exclusions'}{'928601'} = ' pagers only';
	$self->{'Exclusions'}{'928801'} = ' pagers only';
	$self->{'Exclusions'}{'928802'} = ' pagers only';
	$self->{'Exclusions'}{'928803'} = ' pagers only';
	$self->{'Exclusions'}{'928804'} = ' pagers only';
	$self->{'Exclusions'}{'928805'} = ' pagers only';
	$self->{'Exclusions'}{'928806'} = ' pagers only';
	$self->{'Exclusions'}{'928807'} = ' pagers only';
	$self->{'Exclusions'}{'928808'} = ' pagers only';
	$self->{'Exclusions'}{'928901'} = ' pagers only';
	$self->{'Exclusions'}{'928906'} = ' pagers only';
	$self->{'Exclusions'}{'602601'} = ' pagers only';
	$self->{'Exclusions'}{'520701'} = ' pagers only';
	$self->{'Exclusions'}{'520702'} = ' pagers only';
	$self->{'Exclusions'}{'520706'} = ' pagers only';

	print "Rates initialized\n" if $self->{Verbose};
	return $self;
}

1;
