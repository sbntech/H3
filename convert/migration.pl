#!/usr/bin/perl

use strict;
use warnings;
use lib('/dialer/www/perl');
use DialerUtils;

# Notes:
# http://la.sbntele.com/scripts/cust/sys.php   - execute the code in txt  "?txt=ls"

my $cookies = '/tmp/cookies';
my $tfile1 = '/tmp/migfile1';
my $dbh = DialerUtils::db_connect();

sub reseller_login {
	my $username = shift;
	my $passwd = shift;

	system("curl -s -b $cookies -c $cookies 'http://la.sbntele.com/scripts/reseller/checkreseller.php?userame=$username&password=$passwd'");
	# system("cat $cookies");
}

sub do_dialfiles {
	my $project = shift;

	chdir("/dialer/projects/_$project/dialfiles") or warn "failed to chdir: $!";

	opendir(PJDIR, ".") or warn "failed to open dialfiles directory: $!";;
	my @df = readdir(PJDIR);
	closedir(PJDIR);

	my %dfiles;
	for my $f (sort @df) {
		next if $f =~ /^\./;

		system("sed -r -i -e '/(<b>Warning|^<br .>)/d' $f"); # remove stupid php warnings an artifact of the download2.php program

		if ($f =~ /(.*)-([A-Z]{4})-(\d*)$/) {
			my ($fname, $carr, $tz) = ($1, $2, $3);
			if (($carr ne 'XXXX') && ($carr ne 'NOGR')) { # skip NOGR/XXXX files
				# read file appending numbers after the seek to mig-$fname
				open(DF, "<", $f);

				my $buf;
				read(DF, $buf, 4);
				my $offset = unpack("i", $buf);
				seek(DF, $offset, 0) or next;

				if (eof(DF)) {
					print "dialfile:$f is all used up\n";
				} else {
					my $count = 0;
					open(NEWF, ">>", "mig-$fname") or die "Could not open mig-$fname for $project: $!";
					while (! eof(DF)) {
						$buf = <DF>;
						last if(length($buf)<2);
						$buf=~s/[^\d\:]//g;
						print NEWF "$buf\n";
						$count++;
					}
					close(NEWF);

					print "dialfile:$f has $count leads\n";
					$dfiles{$fname} += $count;
				}
				close(DF);
			}
		}
		print "removing dialfile _$project/dialfiles/$f\n";
		unlink($f);
	}

	for my $mf (keys %dfiles) {
		if ($dfiles{$mf} > 0) {
			system("mv '/dialer/projects/_$project/dialfiles/mig-$mf' '/dialer/projects/_$project/dialfiles/$mf'");
# TODO convfile used to call Leads::convert after selecting project and customer data - it no longer exists!!!			system("perl /dialer/convert/convfile.pl $project $mf T T N");
			print "=========================================>  _$project/dialfile/$mf had " . $dfiles{$mf} . " numbers and was converted\n";
		}
	}

}

sub do_projfiles {
	my $pjid = shift;

	for my $pdir ('voiceprompts', 'dialfiles') {
		system("curl -s -b $cookies -c $cookies 'http://la.sbntele.com/scripts/cust/showfiles.php?projectID=$pjid&fShow=$pdir' > $tfile1");
		open(IN, '<', $tfile1);
		while (<IN>) {
			if (/.*(dir|file).gif.*alt="([^"]*)".*/) {
				print "wgetting ---> /dialer/projects/_$pjid/$pdir/$2\n";
				system("wget -q -O '/dialer/projects/_$pjid/$pdir/$2' 'http://la.sbntele.com/scripts/cust/download2.php?path=/dialer/projects/_$pjid/$pdir/$2'"); 
			}
		}
		close(IN);
	}

	do_dialfiles($pjid);
}

sub do_projects {
	my $customer = shift;
	my $rsell = shift;

	my %pjnumbers;

	system("curl -s -b $cookies -c $cookies 'http://la.sbntele.com/scripts/cust/projects.php?Customer_ID=$customer' > $tfile1");

	open(IN, '<', $tfile1);
	print "customer $customer has projects ---> ";
	while (<IN>) {
		if (/javascript:goedit."(\d*)"/) {
			print "$1 ";
			$pjnumbers{$1} = 1;
		}
	}
	close(IN);
	print "\n";

	for my $pjid (keys %pjnumbers) {
		print "    /* ---- Project: $pjid ---- */\n";
		system("curl -s -b $cookies -c $cookies 'http://la.sbntele.com/scripts/cust/editRow.php?mode=EDIT&recordid=$pjid&tfields=*&efields=*&tablename=project&idfield=PJ_Number' > $tfile1");
		system("mkdir -p /dialer/projects/_$pjid/voiceprompts");
		system("mkdir -p /dialer/projects/_$pjid/dialfiles");
		system("mkdir -p /dialer/projects/_$pjid/cdr");
		system("chown -R www-data:www-data /dialer/projects/_$pjid");
		system("chown -R www-data:mysql /dialer/projects/_$pjid/dialfiles");
		system("chmod -R 775 /dialer/projects/_$pjid");

		open(IN, '<', $tfile1);
		my $pjSQL = 'insert into project set ';
		while (<IN>) {
			next if /(PJ_User|PJ_CustNumber)/;
			if (/(name|NAME)="?PJ_\w*"?/) {
				s/.*<INPUT size=\d* maxlength=\d* name=(PJ_\w*) value="([^"]*)".*/$1="$2",/;
				s/.*HIDDEN NAME="?(PJ_\w*)"? value="([^"]*)".*/$1="$2",/;
				s/.*SELECT name="(PJ_[_\w]*)".* value="([^"]*)" selected.*/$1="$2",/;
				s/.*SELECT name="(PJ_[_\w]*)"><\/SELECT>.*"/$1="",/;
				s/.*radio name="(PJ_[_\w]*)".* value="([^"]*)" CHECKED.*/$1="$2",/;
				chomp;
				$pjSQL .= $_;

			}
		}
		$pjSQL .= "PJ_Number='$pjid', PJ_CustNumber='$customer'";
		close(IN);

		#print "\n\nexecuting sql:\n$pjSQL\n\n";
		$dbh->do($pjSQL);

	}

	for my $pjid (keys %pjnumbers) {
		do_projfiles($pjid);
	}
}

die "not been fixed for new number handling";

my $distributor = 'daven873hgy3E6d8cNhw3dig830O0shf';
my $DistribFactor = 3.2778;

my @resellers = (
	# callblazer is not migrated - odd situation
	# nwa has no password
	{ 	RS_Number => 66, RS_Name => 'mortgage07', RS_Password => '1400lake',
		customers => [(11844)],
	},
	{ 	RS_Number => 59, RS_Name => 'damco', RS_Password => '131945rdc',
		customers => [(11529)],
	},
	{ 	RS_Number => 61, RS_Name => 'bankney', RS_Password => 'bengals85',
		customers => [(11654)],
	},
	{ 	RS_Number => 67, RS_Name => 'john07', RS_Password => 'john',
		customers => [(11901, 11911, 11912, 11917, 11939, 11941, 11942)],
	}
);

for my $rsell (@resellers) {

	print "---- Reseller: "  . $rsell->{RS_Name} . " ---- \n";

	reseller_login($rsell->{RS_Name}, $rsell->{RS_Password});

	for my $c (@{$rsell->{customers}}) {
		print "  Customer: $c\n";
		system("curl -s -b $cookies -c $cookies 'http://la.sbntele.com/scripts/reseller/editRow.php?mode=edit&recordid=$c&idfield=CO_Number&tfields=*&efields=CO_Number%2CCO_Name%2CCO_Password%2C+CO_Address%2C+CO_Address2%2C+CO_City%2C+CO_Zipcode%2C+CO_State%2C+CO_Tel%2C+CO_Fax%2C+CO_Email%2CCO_Credit%2C+CO_Bong%2C+CO_Rate%2C+CO_Rate_2%2C+CO_Time_Rate_2%2C+CO_Status%2C+CO_RoundBy%2C+CO_Min_Duration%2C+CO_Priority%2C+CO_Timezone%2C+CO_Maxlines%2C+CO_Checknodial%2CCO_Enablemobile%2CCO_Notifyquick%2CCO_Billingtype&tablename=customer&currow=0&maxrows=3000&rowcount=3000&sortby=&query=+where+CO_ResNumber%3D" . $rsell->{RS_Number} . "&template=&E=TRUE&A=TRUE&V=TRUE&D=FALSE&showQuery=&optionline=' > $tfile1");

		open(IN, '<', $tfile1);
		my $custSQL = 'insert into customer set ';
		while (<IN>) {
			if (/(name|NAME)="?CO_\w*"?/) {
				next if /notifyquick/i;
				s/.*<INPUT size=\d* maxlength=\d* name=(CO_[^ ]*) value="([^"]*)".*/$1="$2",/;
				s/.*(CO_Credit)" value="([^"]*)".*/$1="$2",/;
				s/.*SELECT name="(CO_[_\w]*)".* value="([^"]*)" selected.*/$1="$2",/;
				s/.*radio name="(CO_[_\w]*)".* value="([^"]*)" CHECKED.*/$1="$2",/;
				chomp;
				$custSQL .= $_;
			}
		}
		$custSQL .= "CO_ResNumber='" . $rsell->{RS_Number} . "', CO_Number='$c'";
		close(IN);

		#print "\n\nexecuting sql:\n$custSQL\n\n";
		$dbh->do($custSQL);

		# nodial files
		system("curl -s -b $cookies -c $cookies 'http://la.sbntele.com/scripts/cust/showfiles.php?Customer_ID=$c&fShow=nodial' > $tfile1");
		open(IN, '<', $tfile1);
		while (<IN>) {
			if (/.*(dir|file).gif.*alt="([^"]*)".*/) {
				my $lfile = "/tmp/nodial-$2";
				print "wgetting nodial file ============> $2\n";
				system("wget -q -O '$lfile' 'http://la.sbntele.com/scripts/cust/download2.php?path=/dialer/projects/nodial/$2'"); 
				DialerUtils::clean_file($lfile, $lfile);
				chmod(0664, $lfile); # mysql wants the file world readable
				$dbh->do("load data infile '$lfile' ignore into table dnccust (PhNumber) set CustNumber = $c");
				unlink($lfile);
			}
		}
		close(IN);

		do_projects($c, $rsell);
	}
}

$dbh->disconnect;
