#!/usr/bin/perl

package ProjectSupport;

use strict;
use warnings;

use Apache2::Const qw(:methods :common);
use DateTime;

sub handler {
	my $r = shift;

	my $template = 'ProjectSupport.tt2';
	my $req = Apache2::Request->new($r, 
		POST_MAX => 2*1024*1024,
		DISABLE_UPLOADS => 1);

	my $dbh = DialerUtils::db_connect(); 
	my $data = DialerUtils::step_one($req, $dbh,
		$req->param->{'CO_Number'}, 
		$req->param->{'PJ_Number'});

	if ((defined($data->{'ErrStr'})) && (length($data->{'ErrStr'}) > 0)) {
		$data->{'ErrStr'} .= "\nAuthorization failed";
	} elsif ($data->{'Z_PJ_Permitted'} ne 'Yes') {
		$data->{'ErrStr'} .= " Not authorized. Try to login again";
	} else { 
		# logged in so ...
		if (! defined($data->{'X_Method'})) {
			# drop through and display
		} elsif ($data->{'X_Method'} eq 'History') {
			$template = 'ProjectSupportHist.tt2';

			$data->{'Hist'} = $dbh->selectall_arrayref("select 
				date(SU_DateTime) as Day, 
				time(SU_DateTime) as Time,
				SU_Nickname, SU_Message from support
				where SU_Project = '" . $data->{'PJ_Number'} . "' 
				order by SU_DateTime", { Slice => {}});
		} elsif (substr($data->{'X_Method'},0,4) eq 'Send') {
			# new message sent
	
			# mangle the message
			if (! ($data->{'SU_Message'} =~ s/(http:\/\/\S*)/<a href="$1" target="_blank">$1<\/a>/g)) {
				$data->{'SU_Message'} =~ s/&/&amp;/g;
				$data->{'SU_Message'} =~ s/</&lt;/g;
				$data->{'SU_Message'} =~ s/>/&gt;/g;
			}
			$data->{'SU_Message'} =~ s/[\r\n]{1,}/<br\/>/g;

			my $status = '';
			my $level = $data->{'Session'}{'L_Level'};
			if ($level == 6) { 
				# finan/tech
				$status = 'R';
			} elsif ($data->{'ContextProject'}{'PJ_Support'} eq 'R') {
				$status = 'O';
			}

			if ($data->{'X_Method'} eq 'Send and Open') {

				$status = 'O';

				$dbh->do("insert into support
					set SU_Project = '" . $data->{'PJ_Number'} . "',
					SU_DateTime = date_sub(now(), interval 1 second),
					SU_Nickname = '__SYSTEM', SU_Message = 'Status changed to open.'");
			}

			if (length($data->{'SU_Message'}) > 0) {
				my $sth = $dbh->prepare("insert into support
					set SU_Project = '" . $data->{'PJ_Number'} . "',
					SU_DateTime = now(),
					SU_Nickname = ?, SU_Message = ?");

				$sth->execute($data->{'SU_Nickname'},
					$data->{'SU_Message'});
			}

			if ($data->{'X_Method'} eq 'Send and Close') {

				$status = 'C';

				$dbh->do("insert into support
					set SU_Project = '" . $data->{'PJ_Number'} . "',
					SU_DateTime = date_add(now(), interval 1 second),
					SU_Nickname = '__SYSTEM', SU_Message = 'Status changed to closed.'");
			}

			if (length($status) > 0) {
				$data->{'ContextProject'}{'PJ_Support'} = $status;
				$dbh->do("update project set PJ_Support = '$status'
					where PJ_Number = '" . $data->{'PJ_Number'} . "'");
			}				
		}
	}
	$dbh->disconnect;

	# render the page
	$req->content_type('text/html');
	my $tt = Template->new(INCLUDE_PATH => '/dialer/www/perl')
		|| die $Template::ERROR, "\n";
	$tt->process($template, $data) || die $tt->error(), "\n";

	return Apache2::Const::OK;
}
1;
