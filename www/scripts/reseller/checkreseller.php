<?
$checkPass = "NO";
require("/dialer/www/settings.inc.php");

session_start();
$_SESSION["L_Level"] = 0;
$_SESSION["L_Name"] = '';
$_SESSION["L_Number"] = 0; 
$_SESSION["L_OnlyCustomer"] = 0;
$_SESSION["L_OnlyReseller"] = 0; 
$_SESSION["L_LoginPage"] = "/scripts/reseller/index.php?errormsg=";

$username = strtolower($_REQUEST["username"]);
$password = $_REQUEST["password"];

$SQLStmt = "select RS_Number,RS_Password,RS_Name from reseller where RS_Name='$username' and RS_Password='$password'";
$result = mysql_query($SQLStmt);

if ($row = mysql_fetch_array ($result)) {
	$_SESSION["L_Level"] = 5;
	$_SESSION["L_Name"] = $row["RS_Name"];
	$_SESSION["L_Number"] = 0; 
	$_SESSION["L_OnlyCustomer"] = 0;
	$_SESSION["L_OnlyReseller"] = $row["RS_Number"]; 
    header("location: main.php");
    exit;
}
$result =urlencode("Access denied. Incorrect credentials.");
header("location: " . $_SESSION["L_LoginPage"] . "$result");
exit;
?>
