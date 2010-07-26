<?
require("/dialer/www/settings.inc.php");

$SQLStmt = "SELECT * FROM customer WHERE CO_Number=" . $CO_Number;
$result = mysql_query($SQLStmt);
$row = mysql_fetch_array ($result);
?>
<html>
<head>
<title><?echo $row['CO_Name'] . " (" . $_SESSION["L_Name"] . ")";?></title>
<LINK REL="stylesheet" TYPE="text/css" href="/glm.css">
<script type="text/javascript" src="/glm.js"></script>
<script>

var SessCookie = getCookie('PHPSESSID');

<?
echo("// CO_ResNumber=" . $row['CO_ResNumber']);
?>

</script>
</head>
<body class="subpage">
<div class="buttonbar">
<input type="button" onclick="window.location = '/pg/ProjectList?CO_Number=<? echo $CO_Number;?>'" value="All Projects"></input
><input type="button" onclick="window.location = '/pg/ProjectList?CO_Number=<? echo $CO_Number;?>&ActiveOnly=Yes'" value="Active Projects"></input
><input type="button" onclick="window.location = '/pg/CustomerNodial?CO_Number=<? echo $CO_Number;?>'" value="DNC"></input><?
	if ($_SERVER['SERVER_NAME'] == 'localhost') { ?>
<input type="button" onclick="window.open('https://localhost/pg/Payment?CO_Number=<? echo $CO_Number;?>&HTTP_Host=localhost&SessionId=' + SessCookie)" value="Payment [TEST]"></input><?
	} elseif ($row['CO_ResNumber'] == 1) { ?>
<input type="button" onclick="window.open('https://secure.sbndials.com/pg/Payment?CO_Number=<? echo $CO_Number;?>&HTTP_Host=secure.sbndials.com&SessionId=' + SessCookie)" value="Payment"></input><?
	} elseif (($row['CO_ResNumber'] == 77) || ($row['CO_ResNumber'] == 123)) { ?>
<input type="button" onclick="window.open('https://secure.bullseyebroadcast.com:4431/pg/Payment?CO_Number=<? echo $CO_Number;?>&HTTP_Host=secure.bullseyebroadcast.com:4431&SessionId=' + SessCookie)" value="Payment"></input
><input type="button" onclick="window.open('http://www.bullseyebroadcast.com/Video%20Training/PDS%20Training2.html')" value="Predictive Dialing Training"></input
><input type="button" onclick="window.open('http://www.bullseyebroadcast.com/Voice%20Broadcasting%20Training/VB%20Training.html')" value="Voice Broadcasting Training"></input><?
	}
if ($_SESSION["L_Level"] >= 4) { ?>
<input type="button" onclick="window.location = '/scripts/cust/table.php?CO_Number=<? echo $CO_Number;?>&table=users'" value="Users"></input
><?} ?><input type="button" onclick="window.location = '/scripts/cust/table.php?CO_Number=<? echo $CO_Number;?>&table=agent'" value="Agents"></input
><input type="button" onclick="document.location.href='logout.php'" value="Logoff"></input><a style="vertical-align: bottom;" class="help" href="/help/customer-help.shtml" target="_help"><img style="padding-left:4mm" src="/help/icon-help.png"/></a>
</div><div class="mainPage">
<h2>Customer: <? echo $row['CO_Name'] ?></h2>
<table<tr><td style="vertical-align: top; padding-right: 10mm">
<table cellspacing=1>
<tr><th class="basiclist-row">Balance</th><td class="basiclist-right"><? echo round($row['CO_Credit'],2) ?></td></tr>
<tr><th class="basiclist-row">Authorized Agents</th><td class="basiclist-right"><? echo $row['CO_AuthorizedAgents'] ?></td></tr>
<tr><th class="basiclist-row">Time Zone</th><td class="basiclist"><? 
	$TZlookup['0'] = 'Eastern';
	$TZlookup['-1'] = 'Central';
	$TZlookup['-2'] = 'Mountain';
	$TZlookup['-3'] = 'Pacific';
	echo $TZlookup[$row['CO_Timezone']]; 
?></td></tr>
</table><br/>
<form action="getdayreport.php" METHOD=POST>
<input type=hidden name="CO_Number" value="<? echo $CO_Number ?>">
<table width=223 border=0 cellspacing=0 cellpadding=8 
	style="border-right: thin outset;border-top: thin outset;border-left: thin outset;border-bottom: thin outset;background-color: buttonface">
	<TR><TD align=middle colspan=2>Generate a report</TD></TR>
	<tr><td>from</td><td><INPUT type=text name="DateReportfrom" value="<? echo date("Y-m-d");?>"></td></tr>
	<tr><td>to</td><td><INPUT type=text name="DateReporttill" value="<? echo date("Y-m-d");?>"></td></tr>
	<TR><TD></TD><TD><INPUT id=button3 type=submit size=25 value=Download name=button3 style="WIDTH: 75px"></TD></TR>
</TABLE>
</td><td style="vertical-align: top; -left: 50mm; border: 2px solid #e0e0e0;">
<h2 style="text-align: center; background-color: #e0e0e0">News</h2>
<table style="width: 400px">
<tr><td nowrap="true" style="vertical-align: top; font-weight: bolder">May 27:</td><td>
<a style="float:right" class="help" href="/help/agent-help.shtml#agent-buttons" target="_help"><img src="/help/icon-help.png"/></a>
Agents on cold calling projects can now transfer prospects from the pop-up page. They still need to dial * on the dialpad to complete the transfer or 00 to abandon it.
</td></tr>
<tr><td nowrap="true" style="vertical-align: top; font-weight: bolder">Apr 22:</td><td>Cold calling projects now have the option of recording the calls. There are state laws governing call recording, make sure those laws are obeyed.
</td></tr>
</table>
</td></tr></table>
</div>
</body>
</html>
