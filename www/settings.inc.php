<?
session_start();

$ServerName=`hostname`;
$ServerName = str_replace("\n","",$ServerName);

if (($ServerName == "swift") || ($ServerName == "vaio")) {
	if (! mysql_connect("localhost", "root", "sbntele")) {
		die("Database connection failed");
	}
} elseif ($ServerName == "worker0"){
	if (! mysql_connect("10.9.2.16", "root", "sbntele")) {
		die("Database connection failed");
	}
} else {
    die("Error getting server name [$ServerName]");
}

mysql_select_db("dialer") or die("no dialer db");

$CO_Number = isset($_REQUEST['CO_Number']) ? $_REQUEST['CO_Number'] : 0;
$PJ_Number = isset($_REQUEST['PJ_Number']) ? $_REQUEST['PJ_Number'] : 0;

if ((isset($resellCheck)) && ($resellCheck == "YES")) {
	if ((! isset($_SESSION["L_Level"])) or 
		($_SESSION["L_Level"] != 5)) {
        header("Location:" . $_SESSION["L_LoginPage"] . "Not%20logged%20in");
		exit;
    }
}

if ((!isset($checkPass)) || ($checkPass=="")) {
	if ((! isset($_SESSION["L_Level"])) or 
		($_SESSION["L_Level"] == 0)) {
        header("Location:" . $_SESSION["L_LoginPage"] . "Not%20logged%20in");
		exit;
    }
	if ((isset($_SESSION["L_OnlyCustomer"])) and 
		($_SESSION["L_OnlyCustomer"] > 0) and
		($_SESSION["L_OnlyCustomer"] != $CO_Number)) {
        header("Location:" . $_SESSION["L_LoginPage"] . "Not%20authorized%20on%20this%20customer");
		exit;
    }
}
?>
