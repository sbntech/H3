<?
  require("/dialer/www/settings.inc.php");
?>
<HTML>
<HEAD>
<TITLE>Administration</TITLE>
<LINK REL="stylesheet" TYPE="text/css" href="/glm.css">
</head>
<body>
<?

 $SQLStmt = "select *,
 	(select concat(SU_Nickname,': ',SU_Message) from support where SU_Project = PJ_Number order by SU_DateTime desc limit 1) as LastMessage
 from project, customer, reseller 
 where RS_Number = CO_ResNumber and PJ_CustNumber = CO_Number and PJ_Support = 'O'
 order by RS_Number";
 $result = mysql_query($SQLStmt);
?>
<h2>Projects Needing Support</h2>
<table>
<tr>
        <th class="basiclist-col" valign=middle>Reseller</th>
        <th class="basiclist-col" valign=middle>Customer</th>
        <th class="basiclist-col" valign=middle>Description</th>
        <th class="basiclist-col" valign=middle>Last Message</th>
</tr>
<?
while ($row = mysql_fetch_array ($result)) {
	echo "<tr>";
	echo "\t<TD class=basiclist>" .  $row["RS_Number"] . " - " .  $row["RS_Name"] . "</TD>\n";
	echo "\t<TD class=basiclist>" .  $row["CO_Name"] . "</TD>\n";
	echo "\t<TD class=basiclist><a href='/pg/ProjectSupport?CO_Number=". $row["CO_Number"] ."&PJ_Number=" . $row["PJ_Number"] . "' target='_blank'>"
		. $row["PJ_Description"] . "</a></TD>\n";
	echo "\t<TD class=basiclist>" . $row["LastMessage"] . "</TD>\n";
	echo "</tr>";
}
?>
</table><br/>
<h1>Administration</h1>
<p><input type="button" onclick="window.open('/pg/CustomerList')" value="Manage Customers"></input></p>
<p><input type="button" onclick="window.open('/pg/ResellerList')" value="Manage Resellers"></input></p>
<p><input type="button" onclick="window.open('/pg/AgentChargeList')" value="View Agent Charges"></input></p>
<p><input type="button" onclick="window.open('/pg/AddCreditList')" value="View Credits Added"></input></p>
<p><input type="button" onclick="window.location = '/pg/Militant'" value="Add Militants"></input></p>

<br/>
<Form Name=Form Action="getdayreport.php" METHOD=POST>
<fieldset style="width:400px"><legend>Daily Financial Report</legend>
<br/>
<table>
<tr><td nowrap="true">Customer</td><td><select name="ReportCust">
<option value="0" selected="true">All</option>
<?
 	mysql_free_result ($result);
	$result = mysql_query ("select CO_Number, CO_Name from customer where CO_ResNumber = 1 order by CO_Name");
	while ($row = mysql_fetch_array($result)) {
		echo "<option value=\"" . $row['CO_Number'] . "\">" .
			sprintf("%5s - %s", $row['CO_Number'], $row['CO_Name']) .
			"</option>\n";
	}
	mysql_free_result($result);

?>
</select> (optional)</td></tr>
<tr><td nowrap="true">Reseller</td><td><select name="ReportReseller">
<option value="0" selected="tru">All</option>
<?
	$result = mysql_query ("select RS_Number, RS_Name from reseller order by RS_Name");
	while ($row = mysql_fetch_array($result)) {
		echo "<option value=\"" . $row['RS_Number'] . "\">" .
			sprintf("%5s - %s", $row['RS_Number'], $row['RS_Name']) .
			"</option>\n";
	}
	mysql_free_result($result);

?>
</select> (optional)</td></tr>
<tr><td>From</td><td><input type=text name="DateReportfrom" size="12" value="<? echo date("Y-m-d");?>"></input></td></tr>
<tr><td>To</td><td><input type=text name="DateReporttill" size="12" value="<? echo date("Y-m-d");?>"></input></td></tr>
<tr><td></td><td><br/><input type=submit name=button2 value="Get Report"></input></td></tr>
</table>
</fieldset>
</form>
<br/><a href="/fancy/Admin-CC.html">Cold Calling Admin Picture</a>
<br/><a href="/status/allocator.shtml">Allocator Report</a>
<br/><a href="/status/result-stats.html">Call Result Stats</a>
<br/><a href="/fancy/Monthly.log">Monthly Billing Log</a>
<br/>CDR Summary: <a href="http://www.quickdials.com/cdr-summary/cdr-summary.csv">cdr-summary.csv</a>
<br/><a href="http://www.quickdials.com/munin/index.html">Munin Overview</a>
<br/><a href="http://67.209.46.103/">b1-ap (app server, coldcaller) BMC (IPMI)</a>
<br/><a href="http://67.209.46.104/">b1-db (mysql, loadleads) BMC (IPMI)</a>
<br/><a href="http://67.209.46.105/">w129 BMC (IPMI)</a>
<br/><a href="http://67.209.46.106/">w130 BMC (IPMI)</a>
<br/><a href="http://67.209.46.110/">w801 BMC (IPMI)</a>
<br/><a href="http://67.209.46.111/">w802 BMC (IPMI)</a>
<br/><a href="http://67.209.46.112/">w804 BMC (IPMI)</a>
<br/><br/>
<Form Name=Form Action="../cust/logout.php" METHOD=POST>
<input type=submit name=button2 value="Logout"></input>
</form>
</body>
</html>
