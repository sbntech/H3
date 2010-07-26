<?

/* used by resellers : a clone descendent of scripts/beh/getdayreport.php
*/

$resellCheck = "YES";
require("/dialer/www/settings.inc.php");

$RS_Number = $_POST["res_number"];
$ReportFrom = $_POST["DateReportfrom"];
$ReportTo = $_POST["DateReporttill"];

$heading = "Date,CustomerNumber,Customer,Managed By,Project,Project Name,Project Type,Agent,Customer Minutes,Standby Minutes,Dials,ConnectedAgent,Answered,Machine,Fax,No Answer,Bad Number,Customer Cost,Reseller Minutes, Reseller Cost\n";
$SQLStmt = "select re_date, CO_number, CO_Name, CO_ManagedBy, RE_Project, PJ_Description,
case PJ_Type when 'A' then 'Message Delivery' when 'C' then 'Cold Calling' when 'P' then 'Press 1' when 'S' then 'Survey' else 'Unknown' end,
RE_Agent, RE_Tot_Sec/60,RE_AS_Seconds/60, RE_Calls, RE_Connectedagent, RE_Answered,RE_Ansrmachine,RE_Faxmachine,RE_Noanswer,RE_Badnumber,RE_Tot_cost, RE_Res_Tot_cost / RS_Rate, RE_Res_Tot_cost
FROM report 
	left join customer on RE_Customer =CO_Number 
	left join project on RE_Project=PJ_Number 
	left join reseller on RS_Number = CO_ResNumber 
where CO_ResNumber = $RS_Number and RE_Date >= '$ReportFrom' and  RE_Date < '$ReportTo'  and RE_Tot_Sec <> 0 order by CO_Name,RE_Project";

$result = mysql_query($SQLStmt);
if (!$result) {
    die("Invalid query: $SQLStmt\nError: " . mysql_error());
}

$name = "Reseller_$RS_Number-$ReportFrom-$ReportTo.csv";
header("Content-Type: text/comma-separated-values");
header("Content-Disposition: filename=$name");

print($heading);
while ($row = mysql_fetch_row($result)) {
	$sep = "";
	foreach ($row as $column) {
		print("$sep\"$column\"");
		$sep = ",";
	}
	print("\n");
}
?>
