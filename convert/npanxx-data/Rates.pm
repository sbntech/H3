#!/usr/bin/perl

=pod

A ---> Selway
B ---> GCNS

=cut

package Rates;

use strict;
use warnings FATAL => 'all';
use Text::CSV_XS;

our %NpaNxx; # hash: lata, ocn, A, B ...

my $DATADIR = '/home/grant/H3/convert/npanxx-data';

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
		if ($row =~ /^(\d{3,7}),(.*)\s*$/) {
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
sub lookup_number {
	my $self = shift;
	my $number = shift;
	my $CustomerNumber = shift; # optional
	my $ResellerNumber = shift; # optional

	my $ac = substr($number,0,3);
	my $nn4 = substr($number,0,4);
	my $nn5 = substr($number,0,5);
	my $npanxx = substr($number,0,6);
	my $nn7 = substr($number,0,7);
	my @checklist = ( $nn7, $npanxx, $nn5, $nn4, $ac );

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
			($ResellerNumber == 128)    # funguy1950 roy 20-Jan-2010
		   ) {
		    #### !!!! footprint scrubbing needs to be fixed below
			$rh->{'Footprint'} = 1; # cheap USA
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

		if (defined($self->{'CanadaNPANXX'}{$npanxx})) {
			$rh->{'Routable'} = 1;
			
			my $CAroutes = '';
			my $CAalts = '';

			# Selway (A)
#			SELWAYPREFIX: for my $prefix (@checklist) {
#				if (defined($self->{'Selway'}{$prefix})) {
#					$rh->{'Rates'}{'A'} = $self->{'Selway'}{$prefix};
#					$CAroutes .= 'A';
#					last SELWAYPREFIX;
#				}
#			}

			if (length($CAroutes) > 1) {
				$rh->{'BestCarriers'} = $CAroutes;
				$rh->{'AltCarriers'} = $CAalts;
				$rh->{'ScrubType'} = undef;
			}
		}
	} else { # U.S.A. 
		# determine best and alternate carriers
		my $BestCarriers = '';
		my $AltCarriers = '';

		# B. GCNS
		if (defined($self->{'GCNS'}{$npanxx})) {
			$rh->{'Rates'}{'B'} = $self->{'GCNS'}{$npanxx};
			$rh->{'Routable'} = 1;
			if ($rh->{'Rates'}{'B'} < 0.018) {
				$BestCarriers = 'B';
			}
		}

		# A. Selway
		$rh->{'Rates'}{'A'} = 0.01490; # default interstate rate
		SELWAYPREFIX: for my $prefix (@checklist) {
			if (defined($self->{'Selway'}{$prefix})) {
				$rh->{'Rates'}{'A'} = $self->{'Selway'}{$prefix};
				$rh->{'Routable'} = 1;
				if ($BestCarriers eq '') {
					$BestCarriers = 'A';
				}
				last SELWAYPREFIX;
			}
		}

		if ($rh->{'Routable'} == 1) {
			$rh->{'BestCarriers'} = $BestCarriers;
			$rh->{'AltCarriers'} = $AltCarriers;
			$rh->{'ScrubType'} = undef;
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
sub initialize {
	my $class = shift;
	my $verbose = shift;
	my $self = { Verbose => $verbose };
	bless $self;

	print "Rates initializing verbosely\n" if $self->{Verbose};

	$self->load_canada_file;
	$self->load_areacodes;
	$self->load_telcodata;
	$self->load_rate_file("$DATADIR/Selway.csv", 'Selway', 'A');
	$self->load_rate_file("$DATADIR/GCNS.csv", 'GCNS', 'B');

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
