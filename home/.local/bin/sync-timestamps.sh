#!/bin/bash

# Check if two arguments are provided
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <file_a> <file_b>"
    exit 1
fi

FILE_A=$1
FILE_B=$2

# Ensure both files exist
if [ ! -f "$FILE_A" ]; then
    echo "Error: File '$FILE_A' not found."
    exit 1
fi

if [ ! -f "$FILE_B" ]; then
    echo "Error: File '$FILE_B' not found."
    exit 1
fi

# Get modification times in seconds since epoch
# Note: Syntax for 'stat' varies by OS. This works on Linux (GNU).
MTIME_A=$(stat -c %Y "$FILE_A")
MTIME_B=$(stat -c %Y "$FILE_B")

# Compare dates and apply the earliest timestamp to both
if [ "$MTIME_A" -lt "$MTIME_B" ]; then
    echo "File '$FILE_A' is older. Syncing '$FILE_B' to match."
    touch -r "$FILE_A" "$FILE_B"
elif [ "$MTIME_B" -lt "$MTIME_A" ]; then
    echo "File '$FILE_B' is older. Syncing '$FILE_A' to match."
    touch -r "$FILE_B" "$FILE_A"
else
    echo "Both files have the same modification timestamp."
fi
