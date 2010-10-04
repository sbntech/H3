<?
	/* used to bill customers */
	
	require("/dialer/www/settings.inc.php");
	$DateReportfrom = $_POST['DateReportfrom'];
	$DateReporttill = $_POST['DateReporttill'];
	$ReportCust 	= $_POST['ReportCust'];
	$ReportReseller = $_POST['ReportReseller'];

	$clause = "";
	if ($ReportCust > 0) {
		$clause .= "and RE_Customer = '$ReportCust'";
	} elseif ($ReportReseller > 0) {
		$clause .= "and CO_ResNumber = '$ReportReseller'";
	}

	$heading = "Date,CustomerNumber,ResellerName,DistribCode,DistribFactor,Customer,Project,Project Name,Agent,Minutes,Standby Minutes,Dials,ConnectedAgent,Answered,Machine,Fax,No Answer,Bad Number,Revenue\n";
	$SQLStmt = "select re_date,CO_number,RS_Name,RS_DistribCode,RS_DistribFactor,CO_Name,RE_Project,PJ_Description,RE_Agent,
		round((IF(RS_Number = 1,RE_Tot_Sec,RE_Res_Sec))/60,1),
		round(RE_AS_Seconds/60,1),
		RE_Calls,RE_Connectedagent,RE_Answered,RE_Ansrmachine,RE_Faxmachine,RE_Noanswer,RE_Badnumber, 
		round(IF(RS_Number = 1,RE_Tot_cost,if(length(RS_DistribCode) > 10, RE_Res_Tot_cost / RS_DistribFactor, RE_Res_Tot_Cost)),2) as revenue 
		FROM report 
			left join customer on RE_Customer = CO_Number 
			left join project on RE_Project = PJ_Number 
			left join reseller on CO_ResNumber = RS_Number 
		where RE_Date >= '$DateReportfrom' and RE_Date < '$DateReporttill' and RE_Tot_Sec <> 0 $clause 
		order by RS_DistribCode,CO_ResNumber,CO_Name,RE_Project,RE_Date";

	$result = mysql_query($SQLStmt);

	// send results
	$name = "Finan_$DateReportfrom-$DateReporttill.csv";
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
