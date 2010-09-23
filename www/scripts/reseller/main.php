<?
header('P3P: policyref="http://www.quickdials.com/w3c/p3p.xml",CP="ALL"');
$resellCheck = "YES";
require("/dialer/www/settings.inc.php");

if ($_SERVER['SERVER_NAME'] == 'localhost') {
	$ServerName = "localhost";
} else {
	$ServerName = "secure.quickdials.com";
}		
?>
<html>
<head>
<title>Reseller</title>
<link REL="stylesheet" TYPE="text/css" href="/glm.css">
<script type="text/javascript" src="/glm.js"></script>
<script language="JavaScript">
var SessCookie = getCookie('PHPSESSID');
<?
$RS_Number = $_SESSION["L_OnlyReseller"];
?>
setInterval('window.location.reload()',120000);
</SCRIPT>
</head><body style="margin: 10 10 10 10">
<?
$SQLStmt = "SELECT RS_Number, RS_Name, RS_Credit, RS_DistribCode, RS_DistribFactor 
	FROM reseller WHERE RS_Number=$RS_Number";
$result = mysql_query($SQLStmt);
$row = mysql_fetch_array ($result);
?>
<h2>Reseller: <? print $row["RS_Name"]; ?></h2>
<table class="editForm" cellspacing=1>
<tr><td class="editFormLabel"> Balance </td><td class="editFormInput"><? 
	print round($row["RS_Credit"],2); 
	if ((strlen($row["RS_DistribCode"]) == 0) && ($row["RS_Number"] != 127) && ($row["RS_Number"] != 128)) {?>&nbsp;<input type="button" 
		onclick="window.open('https://<? echo $ServerName; ?>/pg/Payment?RS_Number=<? echo $RS_Number; ?>&HTTP_Host=<? echo $ServerName; ?>&SessionId=' + SessCookie)" 
		value="Make a Payment"></input>
<? } ?>
 	</td></tr>
<tr><td class="editFormLabel"> Manage </td><td class="editFormInput"><input type="button" onclick="window.open('/pg/CustomerList')" value="Customers"></input></td> </tr>
<tr><td class="editFormLabel"> View </td><td class="editFormInput"><input type="button" onclick="window.open('/pg/AgentChargeList')" value="Agent Charges"></input></td> </tr>
<tr><td class="editFormLabel"> Report </td>
	<td class="editFormInput">
	<form action="getdayreport.php" METHOD=POST>
	<input type=hidden name="res_number" value="<? echo $row["RS_Number"] ?>">
	<table>
	<tr><td>from</td><td><INPUT type=text name="DateReportfrom" value="<? echo date("Y-m-d");?>"></td></tr>
	<tr><td>to</td><td><INPUT type=text name="DateReporttill" value="<? echo date("Y-m-d");?>"></td></tr>
	<tr><td/><td><input type=submit name=button2 value=" Download "></td></tr>
	</table>
	</form></td></tr>
<tr>
	<td class="editFormLabel">Logout</td>
	<td class="editFormInput"><input type="button" onclick="location = '/scripts/cust/logout.php'" value="Logout"></input></td>
</tr>
</table>
<?

 mysql_free_result ($result);
 $SQLStmt = "select *,
 	(select concat(SU_Nickname,': ',SU_Message) from support where SU_Project = PJ_Number order by SU_DateTime desc limit 1) as LastMessage
 from project, customer 
 where PJ_CustNumber = CO_Number and CO_ResNumber = $RS_Number and PJ_Support = 'O'";
 $result = mysql_query($SQLStmt);
?>
<br/>
<h2>Projects Needing Support</h2>
<table>
<tr>
        <th class="basiclist-col" valign=middle>Customer</th>
        <th class="basiclist-col" valign=middle>Description</th>
        <th class="basiclist-col" valign=middle>Last Message</th>
</tr>
<?
while ($row = mysql_fetch_array ($result)) {
	echo "<tr>";
	echo "\t<TD class=basiclist>" .  $row["CO_Name"] . "</TD>\n";
	echo "\t<TD class=basiclist><a href='/pg/ProjectSupport?CO_Number=". $row["CO_Number"] ."&PJ_Number=" . $row["PJ_Number"] . "' target='_blank'>"
		. $row["PJ_Description"] . "</a></TD>\n";
	echo "\t<TD class=basiclist>" . $row["LastMessage"] . "</TD>\n";
	echo "</tr>";
}
?>
</table>
<?

 mysql_free_result ($result);
 $SQLStmt = "SELECT PJ_Visible,PJ_Weekend, PJ_Number,PJ_Description,IF(PJ_Status = 'A', 'Active', 'Blocked') as PJ_Status, DATE_FORMAT(PJ_DateStart,'%c-%e') as PJ_DateStart,DATE_FORMAT(PJ_Datestop,'%c-%e') as PJ_Datestop, CONCAT(PJ_TimeStart,':',PJ_TimeStartMin) as PJ_TimeStart,CONCAT(PJ_TimeStop, ':',PJ_TimeStopMin) as PJ_TimeStop, 
	CASE  PJ_Type when 'A' then 'Message Delivery' when 'C' then 'Cold Calling' when 'P' then 'Press 1' when 'S' then 'Survey'  end as PJ_TypeDesc,
 PJ_Maxline, PJ_Timeleft, CO_Name,CO_Number,
 (select RE_Calls from report where RE_Agent = 9999 and RE_Project = PJ_Number and RE_date = current_date()) as RE_Calls,
 (select RE_Answered from report where RE_Agent = 9999 and RE_Project = PJ_Number and RE_date = current_date()) as RE_Answered
 FROM project  left join customer on PJ_Custnumber=CO_Number WHERE CO_ResNumber=$RS_Number and (PJ_DateStart <= current_date() and PJ_DateStop >= current_date()) AND PJ_Visible=1 order by CO_Name, PJ_Description";
 $result = mysql_query($SQLStmt);
?>
<br/>
<h2>Projects</h2>
<TABLE><tr>
        <th class="basiclist-col" valign=middle>Customer</th>
        <th class="basiclist-col" valign=middle>Description</th>
        <th class="basiclist-col" valign=middle>Status</th>
        <th class="basiclist-col" valign=middle>Calls Today</th>
        <th class="basiclist-col" valign=middle>Conn Rate</th>
        <th class="basiclist-col" valign=middle>DateStart</th>
        <th class="basiclist-col" valign=middle>Datestop</th>
        <th class="basiclist-col" valign=middle>Weekend</th>
        <th class="basiclist-col" valign=middle>TimeStart</th>
        <th class="basiclist-col" valign=middle>TimeStop</th>
        <th class="basiclist-col" valign=middle>Type</th>
        <th class="basiclist-col" valign=middle>MaxLine</th>
        <th class="basiclist-col" valign=middle>Run Info</th>
    </tr>
<?
while ($row = mysql_fetch_array ($result)) {
	if ($row['PJ_Weekend'] ==3) {
		$Weekend ="SA & SU";
	} elseif ($row['PJ_Weekend'] ==2) {
		$Weekend ="SU";
	} elseif ($row['PJ_Weekend'] ==1) {
		$Weekend ="SA";
	} else {
		$Weekend ="None";
	}

	$asr = '';
	if ($row['RE_Calls'] > 0) {
		$asr = sprintf('%0.1f%%', 100 * $row['RE_Answered'] / $row['RE_Calls']);
	}

	echo "<TR>";
	echo "\t<TD class=basiclist>" .  $row["CO_Name"] . "</TD>\n";
	echo "\t<TD class=basiclist><a href='/pg/ProjectList?CO_Number=". $row["CO_Number"] ."&PJ_Number=" . $row["PJ_Number"] . "' TARGET='ResellerCustWindow'>"
		. $row["PJ_Description"] . "</a></TD>\n";
	echo "\t<TD class=basiclist>" . $row["PJ_Status"] . "</TD>\n";
	echo "\t<TD class=basiclist>" . $row["RE_Calls"] . "</TD>\n";
	echo "\t<TD class=basiclist>$asr</TD>\n";
	echo "\t<TD class=basiclist>" . $row["PJ_DateStart"] . "</TD>\n";
	echo "\t<TD class=basiclist>" . $row["PJ_Datestop"] . "</TD>\n";
	echo "\t<TD class=basiclist>" . $Weekend . "</TD>\n";
	echo "\t<TD class=basiclist>" . $row["PJ_TimeStart"] . "</TD>\n";
	echo "\t<TD class=basiclist>" . $row["PJ_TimeStop"] . "</TD>\n";
	echo "\t<TD class=basiclist>" . $row["PJ_TypeDesc"] . "</TD>\n";
	echo "\t<TD class=basiclist>" . $row["PJ_Maxline"] . "</TD>\n";
	echo "\t<TD class=basiclist>" . $row["PJ_Timeleft"] . "</TD>\n";
	echo "</TR>";
}

 mysql_free_result ($result);
 ?>
</TABLE>
<BR>
<?


 $SQLStmt = "select CO_Number,CO_Name,
	 CASE  co_status when 'A' then 'Active'  when 'B' then 'Blocked' end as CO_Status,
	 round(CO_Credit,2) as CO_Credit,CO_Tel,CO_Email,
	 CASE  co_Timezone when '0' then 'EST'  when '-1' then 'CENT' when '-2' then 'MTN' when '-3' then 'PST'  end as CO_Timezone,
	 CO_Maxlines
 	 FROM customer WHERE CO_ResNumber=$RS_Number order by CO_Name";
 $result = mysql_query($SQLStmt);
?>
<h2>Customers</h2>
<TABLE>
        <th class="basiclist-col" valign=middle >Customer</th>
        <th class="basiclist-col" valign=middle >Status</th>
        <th class="basiclist-col" valign=middle >Credit</th>
        <th class="basiclist-col" valign=middle >Max lines</th>
        <th class="basiclist-col" valign=middle >Timezone</th>
        <th class="basiclist-col" valign=middle >Telephone</th>
        <th class="basiclist-col" valign=middle >E-mail</th>
    </TR>
<?
while ($row = mysql_fetch_array ($result)) {
	echo "<TR>";
	echo "\t<TD class=basiclist><a href='/scripts/cust/customer.php?CO_Number=". $row["CO_Number"] ."' TARGET='ResellerCustWindow'>" .  $row["CO_Name"] . "</a></TD>\n";
	echo "\t<TD class=basiclist>" . $row["CO_Status"] . "</TD>\n";
	echo "\t<TD class=basiclist>" . $row["CO_Credit"] . "</TD>\n";
	echo "\t<TD class=basiclist>" . $row["CO_Maxlines"] . "</TD>\n";
	echo "\t<TD class=basiclist>" . $row["CO_Timezone"] . "</TD>\n";
	echo "\t<TD class=basiclist>" . $row["CO_Tel"] . "</TD>\n";
	echo "\t<TD class=basiclist>" . $row["CO_Email"] . "</TD>\n";
	echo "</TR>";
}
 mysql_free_result ($result);
 ?>
</table>
</body>
</html>
