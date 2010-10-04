<?

	/* used by customers : a clone descendent of scripts/beh/getdayreport.php
	*/
	
	require("/dialer/www/settings.inc.php");
	$DateReportfrom = $_POST['DateReportfrom'];
	$DateReporttill = $_POST['DateReporttill'];


	$heading = "Date,Project,Project Name,Agent,Minutes,Standby Minutes,Dials,ConnectedAgent,Answered,Machine,Fax,No Answer,Bad Number,Cost\n";
	$SQLStmt = "select re_date,RE_Project as Project,PJ_Description as 'Project name',RE_Agent as Agent, RE_Tot_Sec/60 as Minutes,RE_AS_Seconds / 60,RE_Calls as dials, RE_Connectedagent, RE_Answered answering ,RE_Ansrmachine as mach,RE_Faxmachine as fax,RE_Noanswer as 'NO answ',RE_Badnumber as 'bad num', RE_Tot_cost as cost 
	FROM report left join project on RE_Project=PJ_Number where RE_Customer = $CO_Number and RE_Date >= '$DateReportfrom' and  RE_Date < '$DateReporttill'  and RE_Tot_Sec <> 0 order by RE_Project";

	$result = mysql_query($SQLStmt);

	// send the file
	$name = "Customer-$CO_Number-$DateReportfrom-$DateReporttill.csv";
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
