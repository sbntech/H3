#!/usr/bin/perl

package Users;

use strict;
use warnings;

use Apache2::Const qw(:methods :common);
use JSON;

sub random_password {

	my $pchars = "abcdefghijkmnpqrstuvwxyz98765432";
	my $plen = length($pchars);

	my $p;
	for (my $c = 0; $c < 9; $c++) {
		$p .= substr($pchars, int(rand($plen)), 1);
	}

	$p .= int(rand(100));

	return $p;
}

sub is_blank_str {
	my $v = shift;

	return 1 unless defined($v); # undefined means blank

	$v =~ s/^\s*(.*)\s*$/$1/g;

	return ($v eq '');
}

sub required {
	my $data = shift;
	my $fld = shift;

	if (is_blank_str($data->{$fld})) {
		$data->{$fld . '_ERROR'} = 'Required';
		return 0;
	} else {
		return 1;
	}
}

sub make_an_int {
	my $n = shift;
	return 0 unless defined $n;
	eval {
		$n = sprintf('%d', int($n));
	};
	$n = 0 if $@;
	return $n;
}


sub make_sql {
	my $data = shift;
	my $dbh = shift;

	my $valid = 1;
	my $uniqCheck = "";
	
	my @cols = ('us_name', 'us_password', 'us_level');

	$valid = 0 if required($data,'us_name') == 0;
	$valid = 0 if required($data,'us_password') == 0;

	# cleanse first
	for my $f (@cols) {
		if (defined($data->{$f})) {
			$data->{$f} =~ s/['"]//g;
			$data->{$f} =~ s/^\s*(.*)\s*$/$1/g; # trim
		}
	}

	# us_number
	if (is_blank_str($data->{'us_number'})) {
		if ($data->{'X_Method'} eq 'Update') {
			$data->{'ErrStr'} = 'Users number was missing for Update';
			return undef; # no point continuing, this is serious
		}
	} else {
		if ($data->{'X_Method'} eq 'Insert') {
			$data->{'ErrStr'} = 'Users number cannot be provided for Insert';
			return undef; # no point continuing, this is serious
		}
		$uniqCheck = 'and us_number != ' . $data->{'us_number'};
	}

	# us_customer
	if ($data->{'X_Method'} eq 'Update') {
		my $old = $dbh->selectrow_hashref("select us_customer
			from users where us_number = '" . $data->{'us_number'}
			. "'");
		if (!defined($old->{'us_customer'})) {
			$data->{'ErrStr'} = 'us_number is invalid';
			$valid = 0;
		} elsif ($old->{'us_customer'} != $data->{'us_customer'}) {
			$data->{'ErrStr'} = 'Cannot change customer like this';
			$valid = 0;
		}
	} else {
		$data->{'us_customer'} = $data->{'ContextCustomer'}{'CO_Number'};
	}

	# us_name
	# check for uniqueness
	my $nameFind = $dbh->selectrow_hashref(
		"select count(*) as cnt from users
		where us_name = '" . $data->{'us_name'} .
		"' $uniqCheck");

	if ($nameFind->{'cnt'} > 0) {
		$data->{'us_name_ERROR'} = 'Not unique';
		$valid = 0;
	}

	# us_level
	my $level = make_an_int($data->{'us_level'});
	if (($level <= 0) || ($level > 4)) {
		$data->{'us_level_ERROR'} = 'Not a valid value';
		$valid = 0;
	}
	$data->{'us_level'} = $level;


	return undef unless $valid;

	# it is valid so build the sql
	my $flist = ""; # field list for insert
	my $fval = "";  # field values for insert
	my $set = "";   # set statements for update
	my $sep = '';
	
	for my $f (@cols) {
		my $val = $data->{$f};

		$flist .= "$sep$f";
		$fval .= "$sep'$val'";
		$set .= "$sep$f = '$val'";
		$sep = ',';
	}

	if ($data->{'X_Method'} eq 'Insert') {
		return "insert into users ($flist,us_customer) values ($fval,'" . 
			$data->{'CO_Number'} . "')";
	} else {
		return "update users set $set where " .
			"us_number = " . $data->{'us_number'};
	}
}

sub to_list {
	my $r = shift;
	my $data = shift;

	# return to list
	$r->content_type('text/html');
	print "<html><head><script>window.location='/scripts/cust/table.php?table=users&CO_Number=" .
		$data->{'CO_Number'};

	if ((defined($data->{'us_number'})) && ($data->{'us_number'} > 0)) {
		print "&ItemId=" . $data->{'us_number'};
	}

	print "'</script></head><body/></html>";

	return Apache2::Const::OK;
}

sub handler {
	my $r = shift;

	my $req = Apache2::Request->new($r, 
		POST_MAX => 10*1024,
		DISABLE_UPLOADS => 1);

	my $dbh = DialerUtils::db_connect(); 
	my $data = DialerUtils::step_one($req, $dbh,
		$req->param->{'CO_Number'}, 0);

	my $res;

	if ((defined($data->{'ErrStr'})) && (length($data->{'ErrStr'}) > 0)) {
		$data->{'ErrStr'} .= "\nAuthorization failed";
	} elsif (!defined($data->{'X_Method'})) {
		$data->{'ErrStr'} = "X_Method parameter not specified";
	} elsif ($data->{'Z_CO_Permitted'} ne 'Yes') {
		$data->{'ErrStr'} .= " Not authorized. Try to login again";
	} elsif ($data->{'Session'}{'L_Level'} < 4) {
		$data->{'ErrStr'} .= " Only supervisors can do this";
	}

	if (length($data->{'ErrStr'}) == 0) {
		# logged in so ...

		if ($data->{'X_Method'} eq 'Delete') {
			$dbh->do("delete from users where us_customer = '" .
				$data->{'CO_Number'} . "' and us_number = '" .
				$data->{'us_number'} . "' limit 1");
			return to_list($r, $data);
		} elsif (($data->{'X_Method'} eq 'Insert') || ($data->{'X_Method'} eq 'Update')) {
			my $sql = make_sql($data, $dbh);
			if (defined($sql)) {
				my $sth = $dbh->prepare($sql);
				my $rc = $sth->execute();
				if (! $rc) {
					$data->{'ErrStr'} = "Failed: " . $dbh->errstr;
				} else {
					if ($data->{'X_Method'} eq 'Insert') {
						$data->{'us_number'} = $dbh->last_insert_id(undef,undef,undef,undef);

					}
					return to_list($r, $data);
				}
			}
		} elsif ($data->{'X_Method'} eq 'Edit') {

			my $us = $dbh->selectrow_hashref("select * from users 
				where us_number = '" . $data->{'us_number'} . "' limit 1");

			if (! defined($us->{'us_name'})) {
				$data->{'ErrStr'} = "No such user";
			} else {
				# copy values
				for my $k (keys %{$us}) {
					$data->{$k} = $us->{$k};
				}

				$data->{'X_Method'} = 'Update';
			}

		} elsif ($data->{'X_Method'} eq 'New') {
			# returns a new empty users
			$data->{'X_Method'} = 'Insert';
			$data->{'us_customer'} = $data->{'ContextCustomer'}{'CO_Number'};

			$data->{'us_name'} = "";
			$data->{'us_password'} = random_password();
			$data->{'us_level'} = 1;
		} else {
			$data->{'ErrStr'} = "Method " . $data->{'X_Method'} .
				" is not implemented";
		}
	}
	$dbh->disconnect;

	# render the page
	$req->content_type('text/html');
	my $tt = Template->new(INCLUDE_PATH => '/dialer/www/perl')
		|| die $Template::ERROR, "\n";
	$tt->process('Users.tt2', $data) || die $tt->error(), "\n";

	return Apache2::Const::OK;
}
1;
