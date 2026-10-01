#!/bin/bash

# Check if a filename was provided
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <filename>"
    exit 1
fi

FILE=$1

# Check if the file exists
if [ ! -f "$FILE" ]; then
    echo "Error: File '$FILE' not found."
    exit 1
fi

# Get the extension
EXT="${FILE##*.}"
if [[ "$FILE" != *.* ]]; then
    EXT=""
else
    EXT=".$EXT"
fi

# Get modification time including milliseconds
# %y: last modification time, human-readable
# We use cut to grab the time and the first 3 digits of the nanoseconds
MOD_TIME=$(stat -c %y "$FILE")

# Format: YYYY-MM-DD_HHMMSS.sss
# We use date to parse the stat output and append the milliseconds
FORMATTED_TIME=$(date -d "$MOD_TIME" +"%Y-%m-%d_%H%M%S.%3N")

NEW_NAME="${FORMATTED_TIME}${EXT}"

# Safety check for existing files
if [ -e "$NEW_NAME" ]; then
    echo "Error: Target filename '$NEW_NAME' already exists."
    exit 1
fi

# Rename the file
mv -v "$FILE" "$NEW_NAME"
