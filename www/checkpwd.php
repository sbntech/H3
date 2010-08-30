<?
$checkPass = "NO";
require("/dialer/www/settings.inc.php");

header('P3P: policyref="http://www.quickdials.com/w3c/p3p.xml",CP="ALL"');

# 0 = not logged in
# 1 = {user} only own projects2
# 2 = {user} view other projects
# 3 = {user} edit other projects - cannot create users
# 4 = {customer administrator} aka Supervisor
# 5 = {reseller}
# 6 = {finan}
$_SESSION["L_Level"] = 0;

# mostly useful for audit trails
$_SESSION["L_Name"] = '';

# will be non-zero for levels 1..3
$_SESSION["L_Number"] = 0; 

# 0 = unknown, otherwise it holds a CO_Number
# has > 0 when L_Level <= 4
$_SESSION["L_OnlyCustomer"] = 0;

$_SESSION["L_OnlyReseller"] = 0; 
$_SESSION["L_LoginPage"] = "/start.html?message=";

$username = strtolower($_REQUEST["username"]);
$password = $_REQUEST["password"];

if (($username == "finan") and ($password == "fin421")) {
	# financial admin logged in
	$_SESSION["L_Level"] = 6;
	$_SESSION["L_Name"] = 'Admin';
    header("location: scripts/beh/beheer.php");
    exit;
}





$result = mysql_query(
	"select CO_Number, CO_Name from customer 
	where CO_Name='$username' 
	and CO_Password='$password'
	and CO_Status ='A'");
if (!$result) {
    die('Invalid query: ' . mysql_error());
}

if ($row = mysql_fetch_array ($result)) {
	# customer logged in
	$_SESSION["L_Level"] = 4;
	$_SESSION["L_Name"] = 'Supervisor';
	$_SESSION["L_OnlyCustomer"] = $row["CO_Number"]; 
    header("location: scripts/cust/customer.php?CO_Number=" . $row["CO_Number"]);
    exit;
} 


$result = mysql_query(
	"select * from users 
	where us_name='$username' 
	and us_password='$password'");

if ($row = mysql_fetch_array ($result)) {
	# user logged in
	$_SESSION["L_Level"] = $row["us_level"];
	$_SESSION["L_Name"]  = $row["us_name"];
	$_SESSION["L_Number"]  = $row["us_number"];
	$_SESSION["L_OnlyCustomer"] = $row["us_customer"]; 
	header("location: scripts/cust/customer.php?CO_Number=" . $row["us_customer"]);
	exit;
}

header("location: " . $_SESSION["L_LoginPage"] . "Not%20found");
exit;
?>
