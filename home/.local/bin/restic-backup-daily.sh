#!/bin/bash

export RESTIC_EXCLUSIONS=$RESTIC_REPOSITORY/dev-exclusions.txt

restic --verbose \
    backup --tag music /data/storage/music

restic --verbose \
    backup --tag documents /data/storage/documents \
    --exclude-file=$RESTIC_EXCLUSIONS

restic --verbose \
    backup --tag now /data/now \
    --exclude-file=$RESTIC_EXCLUSIONS

restic --verbose \
    backup --tag hardware /data/storage/hardware \
    --exclude-file=$RESTIC_EXCLUSIONS

restic --verbose \
    forget --tag music \
    --keep-last 42

restic --verbose \
    forget --tag documents \
    --keep-last 84

restic --verbose \
    forget --tag now \
    --keep-last 84

restic --verbose \
    forget --tag hardware \
    --keep-last 3

cp /home/robin/nextcloud/passwords.kdbx /home/robin/aux/onedrive/backups/passwords.kdbx

# sync to OneDrive, throttled to 24Mbit/s
rclone sync /data/aux/onedrive/backups onedrive:robin/backups --bwlimit 3072 -v
