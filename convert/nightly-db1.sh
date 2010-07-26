#!/bin/bash


mysqldump -uroot -psbntele --force dialer | 7z a -si /backup/$(date +%A).database.backup.7z > /dev/null

rsync -av /backup/*.7z 10.9.2.1:/extra-b/sbndials-backup/mysql-data
