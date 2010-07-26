<HTML>
<HEAD>
<TITLE>Reseller login</TITLE>
</HEAD>
<BODY onload="document.Form.username.focus()">
<P align=center>
<Form Name=Form Action="checkreseller.php" METHOD=POST>
<TABLE WIDTH="500" BORDER=0 CELLSPACING=1 CELLPADDING=1>
	<TR><TD colspan=4 align=middle><FONT face=Arial size=7><B>Reseller login</B></FONT></TD></TR>
	<?
	if ($HTTP_GET_VARS['errormsg']) {
	  	$result =urldecode($HTTP_GET_VARS['errormsg']);
	  	print "<tr><td colspan=2></td><td colspan=2><FONT color=red>$result</font></td></tr>";
	}
	?>
	<TR><TD rowspan=3 style="WIDTH: 100px" width=50></TD>
		<TD width=80><FONT face="Ms Sans Serif, Arial" size=2>&nbsp;Username:</FONT></TD>
		<TD width=80><INPUT id=username name=username></TD>
		<TD rowspan=3 style="WIDTH: 100px" width=50></TD></TR>
	<TR><TD><FONT face="Ms Sans Serif, Arial" size=2>&nbsp;Password:</FONT></TD>
		<TD><INPUT id=password type=password name=password></TD></TR>
	<TR><TD></TD>
		<TD align=right><INPUT id=submit1 type=submit value=Submit name=submit1></TD></TR>
</TABLE>
</p>
</Form>
</BODY>
</HTML>
