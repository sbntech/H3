#!/bin/bash

# must have the rsync daemon running on 10.80.2.1

cd /dialer/projects
rsync -rtq --include='*/voiceprompts/live.vox' --include='*/voiceprompts/machine.vox' --include='*/voiceprompts/1.vox' --include='*/voiceprompts/2.vox' --include='*/voiceprompts/3.vox' --include='*/voiceprompts/4.vox' --include='*/voiceprompts/5.vox' --include='*/voiceprompts/6.vox' --include='*/voiceprompts/7.vox' --include='*/voiceprompts/8.vox' --include='*/voiceprompts/9.vox' --include='*/voiceprompts/thanks.vox' --include='*/voiceprompts/wait.vox' --include='*/voiceprompts/paidfor.vox' --include='*/voiceprompts' --exclude='*/*' rsync://10.80.2.1/projects .

for FULLN in `find /dialer/projects -name 'live.vox' -or -name 'machine.vox' -or -name '1.vox' -or -name '2.vox' -or -name '3.vox' -or -name '4.vox' -or -name '5.vox' -or -name '6.vox' -or -name '7.vox' -or -name '8.vox' -or -name '9.vox' -or -name 'thanks.vox' -or -name 'wait.vox' -or -name 'paidfor.vox'`
do
	LINKY=${FULLN%.vox}.ulaw
	if [ ! -L $LINKY ] 
	then
		ln -s $FULLN $LINKY
	fi
done
