<?
require("/dialer/www/settings.inc.php");

# used for users and agents

$table = $_REQUEST["table"];

if ($table == "users") {
	if ($_SESSION["L_Level"] < 4) {
        header("Location:/start.html?message=Not%20authorized");
		exit;
	}
	$header = "Users";
	$urlkey = "us_number";
	$url = "/pg/Users?CO_Number=$CO_Number";

} elseif ($table == "agent") {
	$header = "Agents";
	$urlkey = "AG_Number";
	$url = "/pg/AgentRow?CO_Number=$CO_Number";
} else {
	echo "<html><head><title>Error</title></head><body>Error: $table not implemented</body></html>\n";
	exit;
}
?>
<html>
<head>
<TITLE><?echo $header;?></TITLE>
<link REL="stylesheet" TYPE="text/css" href="/glm.css"></link>
<link type="text/css" href="http://ajax.googleapis.com/ajax/libs/jqueryui/1.7.2/themes/base/jquery-ui.css" rel="Stylesheet" />	
<script type="text/javascript" src="http://ajax.googleapis.com/ajax/libs/jquery/1.4.2/jquery.js"></script>
<script type="text/javascript">

	var GivenItem = parseInt("<? echo $_REQUEST["ItemId"] ?>");
	var ChosenItem = (GivenItem > 0) ? GivenItem : 0;


	function set_Chosen(iid) {
		ChosenItem = iid;
		$("#Alert1").addClass('hidden');
	}

	function get_Chosen(iid) {
		if (iid == null) {
			if (ChosenItem == 0) {
				$("#Alert1").toggleClass('hidden');
				return 0;
			}
		} else {
			ChosenItem = iid;
		}
		
		return ChosenItem;
	}

	function doEdit(iid) {
		iid = get_Chosen(iid);
		if (iid == 0) {
			return;
		}
	
   		location = "<? echo "$url&$urlkey=" ?>" + iid + "&X_Method=Edit";
	}

	function goDelete() {

		var iid = get_Chosen();
		if (iid == 0) {
			return;
		}
	
		if (window.confirm("Confirm delete of " + iid)) {
   		location = "<? echo "$url&$urlkey=" ?>" + iid + "&X_Method=Delete";
		}
	}

</script>
</head>
<BODY class="subpage">
<div class=buttonbar>
<input type="button" onclick="location='/scripts/cust/customer.php?CO_Number=<? echo $CO_Number ?>'" value="Back"></input
><input type="button" onclick="location='<? echo $url ?>&X_Method=New'" value="New"></input
><input type="button" onclick="doEdit()" value="Edit"</input
><input type="button" onclick="goDelete()" value="Remove"></input
></div>
<div class="hidden" id="Alert1"><span class="highlight">&nbsp;&nbsp;Please select one first</span></div>
<div class="mainPage">
<h2 style="display:inline;margin-right:15px;"><? echo $header ?></h2><a class="help" href="/help/<? echo $table ?>-help.shtml" target="_help"><img src="/help/icon-help.png"/></a>
<table>
<?
$ItemId = $_REQUEST["ItemId"];

if ($table == "users") {

	# headings ...
	echo "<tr><th class=\"basiclist-col\">Sel</th>\n";
	foreach (array('Number', 'Name', 'Password', 'Level') as $colhdr) {
		echo "<th class=\"basiclist-col\">$colhdr</th>\n";
	}
	echo "</tr>";

	$result = mysql_query("select * from users 
		where us_customer = '$CO_Number'
		order by us_number");
	if (!$result) {
		die('Invalid query: ' . mysql_error());
	}

	# rows ...
	while ($row = mysql_fetch_array($result)) {
?>
		<tr><td class="basiclist"><input type="radio" id="SelectedItem"
			name="ItemId" value="<? echo $row["us_number"] ?>" 
			onclick="set_Chosen(<? echo $row["us_number"] ?>)"
		<?
		if ($ItemId == $row["us_number"]) {
			echo " checked ";
		}
		?>
		></input></td>
		<td class="basiclist"><? echo $row["us_number"] ?></td>
		<td class="basiclist"><a href="javascript:doEdit(<? echo $row["us_number"] ?>)"><? echo $row["us_name"] ?></a></td>
		<td class="basiclist"><? echo $row["us_password"] ?></td>
		<td class="basiclist"><? 
			$lvl = $row["us_level"];
			if ($lvl == 1) { echo "1 - Only own projects"; }
			elseif ($lvl == 2) { echo "2 - View others projects"; }
			elseif ($lvl == 3) { echo "3 - Edit others projects"; }
			elseif ($lvl == 4) { echo "4 - Supervisor"; }
			else { echo "$lvl - Gremlin"; }
		?></td>
		</tr>

<?

	}

} elseif ($table == "agent") {
	# headings ...
	echo "<tr><th class=\"basiclist-col\">Sel</th>\n";
	foreach (array('Number', 'Name', 'Password', 'Call Back', 'Project', 'Status', 'Bridged To', 'Login Status', 'Paused') as $colhdr) {
		echo "<th class=\"basiclist-col\">$colhdr</th>\n";
	}
	echo "</tr>";

	$result = mysql_query("SELECT agent.*, PJ_Description,
		IF(AG_Status = 'B', 'Blocked', IF(AG_Status = 'A', 'Active', 'Unknown')) as StatusStr,
		IF(AG_MustLogin = 'Y', IF(AG_SessionId is not null, 'Logged on', 'Logged off'), 'N/A') as LoginState
		from agent left join project on AG_Project = PJ_Number 
		where AG_Customer = '$CO_Number'
		order by AG_Project, AG_Number");
	if (!$result) {
		die('Invalid query: ' . mysql_error());
	}

	# rows ...
	while ($row = mysql_fetch_array($result)) {
?>
		<tr><td class="basiclist"><input type="radio" id="SelectedItem"
			name="ItemId" value="<? echo $row["AG_Number"] ?>" 
			onclick="set_Chosen(<? echo $row["AG_Number"] ?>)"
		<?
		if ($ItemId == $row["AG_Number"]) {
			echo " checked ";
		}
		?>
		></input></td>
		<td class="basiclist"><? echo $row["AG_Number"] ?></td>
		<td class="basiclist"><a href="javascript:doEdit(<? echo $row["AG_Number"] ?>)"><? echo $row["AG_Name"] ?></a></td>
		<td class="basiclist"><? echo $row["AG_Password"] ?></td>
		<td class="basiclist"><? echo $row["AG_CallBack"] ?></td>
		<td class="basiclist" title="AG_Project=<? echo $row["AG_Project"] ?>"><? echo $row["PJ_Description"] ?></td>
		<td class="basiclist"><? echo $row["StatusStr"] ?></td>
		<td class="basiclist"><? echo $row["AG_BridgedTo"] ?></td>
		<td class="basiclist"><? echo $row["LoginState"] ?></td>
		<td class="basiclist"><? echo $row["AG_Paused"] ?></td>
		</tr>

<?

	}

} 
?>
</table>
</div>
</body>
</html>
