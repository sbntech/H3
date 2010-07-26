#!/usr/bin/perl

package UiDispatch;

use strict;
use warnings;

use Leads;
use CustomerNodial;
use Customer;
use CustomerList;
use AgentChargeList;
use ResellerCIDList;
use CustomerCIDList;
use Reseller;
use ResellerList;
use AddCreditList;
use ProjectReport;
use ProjectTestCall;
use ProjectSupport;
use Payment;
use Distributor;
use Agent;
use PopupCustom;
use CallDetailRecords;
use CallResult;
use Switch;
use VoicePrompts;
use Militant;
use Signup;
use Project;
use Users;
use AgentRow;
use ProjectList;
use TestHandler;
use ProjectRecordings;

sub handler {
	my $r = shift;

	# url: http://localhost/pg/Leads?m=show&PJ_Number=29596
	
	return Leads::handler($r) 				if ($r->path_info() eq '/Leads');
	return CustomerNodial::handler($r)		if (substr($r->path_info(),0,15) eq '/CustomerNodial');
	return Customer::handler($r)			if ($r->path_info() eq '/Customer');
	return ProjectList::handler($r)			if ($r->path_info() eq '/ProjectList');
	return ProjectRecordings::handler($r)	if (substr($r->path_info(),0,11) eq '/Recordings'); 
	return Project::handler($r)				if ($r->path_info() eq '/Project');
	return Users::handler($r)				if ($r->path_info() eq '/Users');
	return AgentRow::handler($r)			if ($r->path_info() eq '/AgentRow');
	return Signup::handler($r)				if (lc($r->path_info()) eq '/signup');
	return CustomerList::handler($r)		if ($r->path_info() eq '/CustomerList');
	return AgentChargeList::handler($r)		if ($r->path_info() eq '/AgentChargeList');
	return CustomerCIDList::handler($r)		if ($r->path_info() eq '/CustomerCIDList');
	return ResellerCIDList::handler($r)		if ($r->path_info() eq '/ResellerCIDList');
	return Reseller::handler($r)			if ($r->path_info() eq '/Reseller');
	return ResellerList::handler($r)		if ($r->path_info() eq '/ResellerList');
	return AddCreditList::handler($r)		if ($r->path_info() eq '/AddCreditList');
	return ProjectReport::handler($r)		if ($r->path_info() eq '/ProjectReport');
	return ProjectTestCall::handler($r)		if ($r->path_info() eq '/ProjectTestCall');
	return ProjectSupport::handler($r)		if ($r->path_info() eq '/ProjectSupport');
	return Payment::handler($r)				if ($r->path_info() eq '/Payment'); 
	return Militant::handler($r)			if ($r->path_info() eq '/Militant');
	return Distributor::handler($r)			if ($r->path_info() eq '/Distributor'); 
	return Agent::handler($r)				if ($r->path_info() eq '/Agent'); 
	return PopupCustom::handler($r)			if ($r->path_info() eq '/PopupCustom'); 
	return Switch::handler($r)				if ($r->path_info() eq '/Switch'); 
	return CallResult::handler($r)			if ($r->path_info() eq '/CallResult'); 
	return VoicePrompts::handler($r)		if ($r->path_info() eq '/VoicePrompts'); 
	return CallDetailRecords::handler($r)	if (substr($r->path_info(),0,4) eq '/CDR'); 
	return TestHandler::handler($r)	if ($r->path_info() eq '/TestHandler');

	return Apache2::Const::DECLINED;
}
1;
