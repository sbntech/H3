#!/bin/bash

echo "Phone Number, Duration, System AMD, Actual" > Detection-Test.csv

for FPATH in /home/grant/detect-test/DETECT-*-in.ulaw
do
	PHONE=`echo $FPATH | sed -e 's/.*DETECT-\(.*\)-in.ulaw.*/\1/'`
	echo "Phone: $PHONE ($FPATH)"
	
	grep -m1 "CDR.*$PHONE" astdialer.log | sed -e 's/.*,\([0-9]*\),\([A-Z]\{2\}\),W130,.*/\1,\2/' > /tmp/CDR0
	CDR=$(< /tmp/CDR0)
	
	for N in 1 2 3
	do
		play -c1 -r8000 -tul $FPATH
		
		echo -n "$CDR ===> "
	
		# h for human, m for machine, s for silence/indeterminate
		read ACTUALRESULT
		
		# x replays the file
		if [ "x{$ACTUALRESULT}x" != "xxx" ]
		then
			break
		fi
	done
	echo $PHONE,$CDR,$ACTUALRESULT > Detection-Test.csv
	
done