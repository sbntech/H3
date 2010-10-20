-- GRANT ALL PRIVILEGES ON *.* TO root@'%' identified by 'sbntele';

create table support (
  SU_Project integer unsigned not null,
  SU_DateTime datetime not null,
  SU_Nickname varchar(30) not null default 'Anon',
  SU_Message text,
  primary key (SU_Project, SU_DateTime)
) ENGINE = MyISAM;

create table periodicpay (
	PP_Customer int(11) not NULL,
  	PP_ChargeAmount double not null,
	PP_SetupDT datetime not null,
	PP_LastPayDT datetime,
	PP_Error varchar(200),
	PP_Last4 char(4) not null,
	PP_CardDetails text,
	primary key (PP_Customer)
) ENGINE = MyISAM;

create table dialer.agentcharge (
	AC_Customer int(11) not NULL,
	AC_DateTime datetime not null,
	AC_AgentsBefore int(11) not null default '0',
	AC_AgentsAfter int(11) not null default '0',
  	AC_CustCharge double not null default '0',
  	AC_ResCharge double not null default '0',
	AC_Error text,
	primary key (AC_Customer, AC_DateTime)
) ENGINE = MyISAM;

create table dialer.rescallerid (
	RC_CallerId char(10) not NULL,
	RC_Reseller int(11) not NULL,
	RC_DefaultFlag char(1) not NULL default 'N',
	RC_CreatedOn datetime not null,
	primary key (RC_Reseller, RC_CallerId)
) ENGINE = MyISAM;

create table dialer.custcallerid (
	CC_CallerId char(10) not NULL,
	CC_Customer int(11) not NULL,
	CC_CreatedOn datetime not null,
	primary key (CC_Customer, CC_CallerId)
) ENGINE = MyISAM;

CREATE TABLE dialer.numberfiles (
  NF_FileNumber INTEGER UNSIGNED NOT NULL AUTO_INCREMENT,
  NF_Project INTEGER UNSIGNED NOT NULL,
  NF_FileName varchar(80)  NOT NULL,
  NF_Uploaded_Time DATETIME  NOT NULL,
  NF_MainScrub CHAR(1) NOT NULL,
  NF_CustScrub CHAR(1) NOT NULL,
  NF_MobileScrub CHAR(1) NOT NULL,
  NF_ScrubDuplicate INTEGER UNSIGNED NOT NULL DEFAULT 0,
  NF_StartTotal INTEGER UNSIGNED NOT NULL DEFAULT 0 COMMENT 'count of usable numbers',
  NF_ColumnHeadings text,
  PRIMARY KEY (`NF_FileNumber`)
) ENGINE = MyISAM;

CREATE TABLE dialer.projectnumbers (
	PN_PhoneNumber char(10)  NOT NULL,
	PN_FileNumber integer UNSIGNED NOT NULL,
	PN_Sent_Time DATETIME,
	PN_Status char(1)  NOT NULL DEFAULT 'R',
	PN_Seq INTEGER unsigned  NOT NULL DEFAULT 0,
	PN_Timezone INTEGER unsigned NOT NULL DEFAULT 0,
	PN_BestCarriers char(9) NOT NULL,
	PN_AltCarriers char(9),
	PN_Disposition integer not null default 0,
	PN_CallResult char(2),
	PN_CallDT datetime,	
	PN_Duration integer,
	PN_SurveyResults varchar(64),
	PN_DoNotCall char(1) not null default 'N',
	PN_Dialer char(4),
	PN_SysInfo varchar(64),
	PN_Agent integer,
	PN_Popdata text,
	PN_Notes text,
	PRIMARY KEY (PN_PhoneNumber),
	KEY SeqKey (PN_Seq)
) ENGINE = MyISAM;

CREATE TABLE numberscache (
  NC_Id INTEGER UNSIGNED NOT NULL auto_increment,
  NC_Project INTEGER UNSIGNED NOT NULL,
  NC_PhoneNumber CHAR(10) NOT NULL,
  PRIMARY KEY (NC_Id)
) ENGINE = MEMORY;

CREATE TABLE addcredit (
  ac_datetime datetime not NULL default '0000-00-00 00:00:00',
  ac_transaction int(11) unsigned not null default 0,
  ac_customer int(11) unsigned DEFAULT NULL,
  ac_amount double default '0',
  ac_user varchar(15) default NULL,
  ac_ipaddress varchar(15) default NULL,
  ac_ResNumber int(11) unsigned default NULL,
  PRIMARY KEY  (ac_datetime, ac_transaction)
) ENGINE=MyISAM;

CREATE TABLE agent (
  AG_Number int(11) NOT NULL auto_increment,
  AG_Password varchar(10) NOT NULL default '',
  AG_Name varchar(20) NOT NULL default '',
  AG_Email varchar(35) NOT NULL default '',
  AG_CallBack varchar(100) NOT NULL default '0',
  AG_Customer int(11) NOT NULL default '0',
  AG_Project int(11) NOT NULL default '0',
  AG_Status char(1) NOT NULL default 'A',
  AG_Lst_change datetime NOT NULL default '0000-00-00 00:00:00',
  AG_SessionId VARCHAR(40)  DEFAULT NULL,
  AG_QueueReady char(1) not null default 'N',
  AG_BridgedTo char(10) default NULL,
  AG_MustLogin char(1) not null default 'N',
  AG_Paused char(1) not null default 'N',
  INDEX `Session`(`AG_SessionId`),
  PRIMARY KEY  (AG_Number)
) ENGINE=MyISAM;

CREATE TABLE customer (
  CO_Number int(11) NOT NULL auto_increment,
  CO_Password varchar(10) NOT NULL default '',
  CO_Name varchar(35) NOT NULL default '',
  CO_Address varchar(40) NOT NULL default '',
  CO_Address2 varchar(40) NOT NULL default '',
  CO_City varchar(25) NOT NULL default '0',
  CO_Zipcode varchar(12) NOT NULL default '',
  CO_State varchar(15) NOT NULL default '',
  CO_Tel varchar(20) NOT NULL default '',
  CO_Fax varchar(20) NOT NULL default '',
  CO_Email varchar(80) NOT NULL default '',
  CO_Credit double NOT NULL default '0',
  CO_Rate double NOT NULL default '0',
  CO_AgentIPRate double NOT NULL default '0',
  CO_Status char(1) NOT NULL default '',
  CO_RoundBy int(11) NOT NULL default '0',
  CO_Min_Duration tinyint(2) unsigned NOT NULL default '0',
  CO_Priority int(11) default '0',
  CO_Timezone varchar(4) default NULL,
  CO_Maxlines int(4) unsigned default '0',
  CO_Checknodial char(1) default 'F',
  CO_OnlyColdCall char(1) not null default 'Y',
  CO_Contact varchar(35) default NULL,
  CO_ManagedBy varchar(40) default null,
  CO_EnableMobile char(1) default 'F',
  CO_Billingtype char(1) NOT NULL default 'T',
  CO_AgentCharge double not null default '0',
  CO_AuthorizedAgents int(11) not null default '0',
  CO_ResNumber tinyint(11) unsigned default '1',
  CO_Callerid text,
  PRIMARY KEY  (CO_Number),
  KEY CO_Name (CO_Name)
) ENGINE=MyISAM;

CREATE TABLE project (
  PJ_Number int(11) NOT NULL auto_increment,
  PJ_Description varchar(20) NOT NULL default '',
  PJ_CustNumber int(11) NOT NULL default '0',
  PJ_Status char(1) NOT NULL default '',
  PJ_DateStart date NOT NULL default '0000-00-00',
  PJ_DateStop date NOT NULL default '0000-00-00',
  PJ_TimeStart int(2) NOT NULL default '0',
  PJ_TimeStartMin tinyint(2) unsigned default '0',
  PJ_TimeStop int(2) NOT NULL default '0',
  PJ_TimeStopMin tinyint(2) unsigned default '0',
  PJ_Type char(1) NOT NULL default '',
  PJ_Maxline smallint(5) unsigned NOT NULL default '0',
  PJ_Type2 char(1) NOT NULL default '',
  PJ_Testcall datetime default NULL,
  PJ_timeleft varchar(20) NOT NULL default '0',
  PJ_Visible tinyint(1) unsigned NOT NULL default '1',
  PJ_PhoneCallC varchar(20) default NULL,
  PJ_Local_Time_Start int(2) default NULL,
  PJ_Local_Time_Stop int(2) default NULL,
  PJ_Local_Start_Min tinyint(2) unsigned default '0',
  PJ_Local_Stop_Min tinyint(2) unsigned default '0',
  PJ_Maxday int(8) unsigned default '0',
  PJ_Weekend char(1) default '0',
  PJ_User int(6) unsigned default NULL,
  PJ_Record char(1) not null default 'N',
  PJ_OrigPhoneNr varchar(15) default NULL,
  PJ_LastCall DATETIME NOT NULL DEFAULT '1999-12-31 23:59:59',
  PJ_DisposDescrip text,  
  PJ_Support char(1) not null default 'C',
  PJ_CallScript text,
  PRIMARY KEY  (PJ_Number),
  KEY status (PJ_Status),
  KEY customer (PJ_CustNumber,PJ_DateStart,PJ_DateStop)
) ENGINE=MyISAM;

CREATE TABLE switch (
  SW_Number int(4) NOT NULL auto_increment,
  SW_IP varchar(20) NOT NULL default '',
  SW_Status char(1) NOT NULL default '',
  SW_ID varchar(4) NOT NULL default '0',
  SW_lstmsg datetime default NULL,
  SW_start datetime NOT NULL default '0000-00-00 00:00:00',
  SW_callsday bigint(20) unsigned default '0',
  SW_callsuur bigint(20) unsigned default '0',
  SW_databaseSRV varchar(20) default NULL,
  SW_tcperror int(10) unsigned default '0',
  SW_VoipCPS int(10) unsigned default '5',
  SW_VoipPorts int(10) unsigned default '0',
  PRIMARY KEY  (SW_Number),
  UNIQUE KEY switch_id (SW_ID)
) Engine=MyISAM;

CREATE TABLE line (
  id bigint(10) NOT NULL auto_increment,
  ln_line varchar(15) default NULL,
  ln_ipnumber varchar(15) default NULL,
  ln_switch varchar(4) default NULL,
  ln_board char(2) default NULL,
  ln_channel char(2) default NULL,
  ln_tasknumber char(3) default NULL,
  ln_dti varchar(5) default NULL,
  ln_status char(1) default NULL,
  ln_info varchar(100) default NULL,
  ln_voice char(1) default NULL,
  ln_PJ_Number int(11) unsigned default '0',
  ln_action int(11) default '0',
  ln_lastused datetime default NULL,
  ln_trunk varchar(4) default NULL,
  ln_AG_Number int(11) unsigned default '0',
  ln_priority char(1) default NULL,
  ln_reson varchar(20) default NULL,
  PRIMARY KEY  (id),
  UNIQUE KEY ln_line (ln_line),
  KEY action (ln_action,ln_ipnumber),
  KEY ln_switch_status (ln_switch,ln_status)
) TYPE=MEMORY;

CREATE TABLE report (
  RE_Number int(11) NOT NULL auto_increment,
  RE_Agent int(11) NOT NULL default '0',
  RE_Project int(11) NOT NULL default '0',
  RE_Date date NOT NULL default '0000-00-00',
  RE_Calls int(11) NOT NULL default '0',
  RE_Bussy int(11) NOT NULL default '0',
  RE_Noanswer int(11) NOT NULL default '0',
  RE_Badnumber int(11) NOT NULL default '0',
  RE_Faxmachine int(11) NOT NULL default '0',
  RE_Ansrmachine int(11) NOT NULL default '0',
  RE_Answered int(11) NOT NULL default '0',
  RE_Hungupduringmsg int(11) NOT NULL default '0',
  RE_Aftermessage int(11) NOT NULL default '0',
  RE_Pressedtone int(11) NOT NULL default '0',
  RE_Connectedagent int(11) NOT NULL default '0',
  RE_Agentnoanswer int(11) NOT NULL default '0',
  RE_Agentbusy int(11) NOT NULL default '0',
  RE_AS_Seconds int(11) NOT NULL default '0',
  RE_Hungupb4connect int(11) NOT NULL default '0',
  RE_0_14_seconds int(11) NOT NULL default '0',
  RE_15_29_seconds int(11) NOT NULL default '0',
  RE_30_59_seconds int(11) NOT NULL default '0',
  RE_1_2_minutes int(11) NOT NULL default '0',
  RE_2_3_minutes int(11) NOT NULL default '0',
  RE_3_5_minutes int(11) NOT NULL default '0',
  RE_5_10_minutes int(11) NOT NULL default '0',
  RE_10_15_minutes int(11) NOT NULL default '0',
  RE_15_over_minutes int(11) NOT NULL default '0',
  RE_Tot_Sec int(11) unsigned NOT NULL default '0',
  RE_Tot_Live_Sec int(10) unsigned NOT NULL default '0',
  RE_Tot_Mach_Sec int(10) unsigned NOT NULL default '0',
  RE_Tot_cost double NOT NULL default '0',
  RE_Tot_cost_exp double default '0',
  RE_Tot_Sec_exp int(11) unsigned NOT NULL default '0',
  RE_Calls_exp int(11) unsigned NOT NULL default '0',
  RE_Customer int(11) unsigned NOT NULL default '0',
  RE_Res_Tot_cost double default '0',
  RE_Res_Sec int(11) unsigned NOT NULL default '0',
  PRIMARY KEY  (RE_Number),
  UNIQUE KEY RE_Project (RE_Project,RE_Agent,RE_Date),
  KEY RE_Agent (RE_Agent)
) ENGINE=MyISAM;

CREATE TABLE reseller (
  RS_Number int(11) NOT NULL auto_increment,
  RS_Password varchar(10) NOT NULL default '',
  RS_Name varchar(35) NOT NULL default '',
  RS_Address varchar(40) NOT NULL default '',
  RS_Address2 varchar(40) NOT NULL default '',
  RS_City varchar(25) NOT NULL default '0',
  RS_Zipcode varchar(12) NOT NULL default '',
  RS_State varchar(15) NOT NULL default '',
  RS_Tel varchar(20) NOT NULL default '',
  RS_Fax varchar(20) NOT NULL default '',
  RS_Email varchar(80) NOT NULL default '',
  RS_Credit double NOT NULL default '0',
  RS_Rate double NOT NULL default '0',
  RS_AgentIPRate double NOT NULL default '0',
  RS_Status char(1) NOT NULL default '',
  RS_RoundBy int(11) NOT NULL default '0',
  RS_Min_Duration tinyint(2) unsigned NOT NULL default '0',
  RS_Priority int(11) default '0',
  RS_Timezone char(2) default NULL,
  RS_Maxlines int(4) unsigned default '0',
  RS_Contact varchar(35) default NULL,
  RS_DistribCode VARCHAR(32) DEFAULT NULL,
  RS_DistribFactor DOUBLE DEFAULT NULL,
  RS_DNC_Flag char(1) NOT NULL default 'Y',
  RS_OnlyColdCall char(1) not null default 'Y',
  RS_AgentCharge double not null default '0',
  RS_AgentChargePerc double not null default '0',
  PRIMARY KEY  (RS_Number),
  KEY RS_Name (RS_Name)
) ENGINE=MyISAM;


CREATE TABLE users (
  us_number int(6) unsigned NOT NULL auto_increment,
  us_name varchar(30) default '0',
  us_password varchar(10) NOT NULL default '',
  us_customer int(11) default '0',
  us_level char(1) default '0',
  PRIMARY KEY  (us_number),
  UNIQUE KEY username (us_customer,us_name),
  UNIQUE KEY user_password (us_name,us_password)
) ENGINE=MyISAM;


INSERT INTO `reseller` VALUES (1,'restart','SBN','123 Hq','Hq','HongKong','90000','US','7027020000','7027020000','hq@main.gov',10000,0.01,0.01,'A',6,6,1,'0',100000,'me',NULL,NULL,'Y','N',0.0,0.0);
INSERT INTO `reseller` VALUES (2,'ohohoh','CanadaTEST','123 Hq','Hq','HongKong','90000','US','7027020000','7027020000','hq@main.gov',10000,0.01,0.005,'A',6,6,1,'0',100000,'me',NULL,NULL,'Y','N',0.0,0.0);
INSERT INTO `reseller` VALUES (79,'Winter1','Bullseye','200 Garden City Plaza','x','Garden City ','11530','NY','866-916-7695','516-706-3533','www.BullseyeBroadcast.com',1105.3264,0.016,0,'A',6,6,5,'0',1000,'Carl DAgostino','',0,'Y','M',0,50);
INSERT INTO `customer` VALUES (1,'123','test','123 Main','yes','NewYork','87871','NY','8160009999','8908900000','yes@maybe.no',100,0.008,0.008,'A',6,6,1,'0',25,'Y','N','me','some foo','Y','T',100.0,4,1,'7027027000\r\n');
INSERT INTO `customer` VALUES (7,'123','carlcust','123 Main','yes','NewYork','87871','NY','8160009999','8908900000','yes@maybe.no',100,0.008,0.0,'A',6,6,1,'0',25,'Y','N','me','some foo','Y','T',100.0,4,79,'7027027000\r\n');
