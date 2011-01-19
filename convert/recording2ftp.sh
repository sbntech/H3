#!/bin/bash

for project in 239 
do
	recorddir="/dialer/projects/_$project/recordings"
	cd $recorddir

	targetdir="/home/cust/project-$project"
	mkdir -p $targetdir

	echo "$recorddir ---> $targetdir"

	for input in *.wav;
	do
		echo "processing $input"
		pcmwav=$(basename "$input" .WAV).wav

		# may be does not need .wav.mp3 - mp3 will be ok
		mp3=$(basename "$pcmwav" .wav).mp3
		sox $input -s $pcmwav
		lame $pcmwav $mp3

		rm $input
		rm $pcmwav

		install --group=cust1 --owner=cust1 --mode=0660 --target-directory=$targetdir $mp3
	done
done
