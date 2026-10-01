#!/bin/bash

RESTIC_REPOSITORY_EXTERNAL=/run/media/robin/ROBIN_PASSPORT/backups/restic
RESTIC_EXCLUSIONS=$RESTIC_REPOSITORY_EXTERNAL/dev-exclusions.txt

# backup

restic --verbose \
    --repo $RESTIC_REPOSITORY_EXTERNAL \
    backup --tag music /data/storage/music

restic --verbose \
    --repo $RESTIC_REPOSITORY_EXTERNAL \
    backup --tag documents /data/storage/documents \
    --exclude-file=$RESTIC_EXCLUSIONS

restic --verbose \
    --repo $RESTIC_REPOSITORY_EXTERNAL \
    backup --tag now /data/now \
    --exclude-file=$RESTIC_EXCLUSIONS

restic --verbose \
    --repo $RESTIC_REPOSITORY_EXTERNAL \
    backup --tag hardware /data/storage/hardware \
    --exclude-file=$RESTIC_EXCLUSIONS

# forget

restic --verbose \
    --repo $RESTIC_REPOSITORY_EXTERNAL \
    forget --tag music \
    --keep-last 3

restic --verbose \
    --repo $RESTIC_REPOSITORY_EXTERNAL \
    forget --tag documents \
    --keep-last 3

restic --verbose \
    --repo $RESTIC_REPOSITORY_EXTERNAL \
    forget --tag now \
    --keep-last 3

restic --verbose \
    --repo $RESTIC_REPOSITORY_EXTERNAL \
    forget --tag hardware \
    --keep-last 1

# prune repo

restic --verbose \
    --repo $RESTIC_REPOSITORY_EXTERNAL \
    prune

cp -vf /home/robin/nextcloud/passwords.kdbx /run/media/robin/ROBIN_PASSPORT/backups/
