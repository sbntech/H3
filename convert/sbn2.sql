-- create database sbn2;
-- GRANT ALL PRIVILEGES ON *.* TO root@'%' identified by 'sbntele';

CREATE TABLE `sbn2`.`phones` (
  `PH_Number` decimal(10) UNSIGNED NOT NULL,
  `PH_CarrierA` decimal(10,9) UNSIGNED,
  `PH_CarrierF` decimal(10,9) UNSIGNED,
  PRIMARY KEY (`PH_Number`)
)ENGINE = MyISAM;

CREATE TABLE sbn2.dncnonconn (
  DN_PhoneNumber char(10) NOT NULL,
  DN_Expires datetime default NULL,
  PRIMARY KEY(DN_PhoneNumber)
) ENGINE=MyISAM;

CREATE TABLE sbn2.custdnc (
  CD_PhoneNumber char(10)  NOT NULL,
  CD_LastContactDT datetime,
  CD_LastContactCust int(11),
  CD_AddedDT datetime,
  CD_AddedCust int(11),
  PRIMARY KEY(`CD_PhoneNumber`)
) ENGINE=MyISAM;

CREATE TABLE sbn2.`dncmilitant` (
  `PhNumber` char(10)  NOT NULL,
  PRIMARY KEY(`PhNumber`)
) ENGINE=MyISAM;

