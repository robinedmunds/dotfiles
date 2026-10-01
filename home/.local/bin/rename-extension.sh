#!/bin/bash

# Check for minimum required arguments
if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <target_ext> <replace_ext> [-r]"
    echo "Options:"
    echo "  -r    Recursive search through subdirectories"
    exit 1
fi

TARGET=$1
REPLACE=$2
RECURSIVE=$3

# Determine search depth
# -maxdepth 1 limits search to current directory
# If -r is passed, we remove the maxdepth constraint
DEPTH_FLAGS="-maxdepth 1"
if [ "$RECURSIVE" == "-r" ]; then
    DEPTH_FLAGS=""
fi

# Use find to locate files.
# We use -print0 and a while loop with IFS= read -r -d ''
# to safely handle filenames with spaces or newlines.
find . $DEPTH_FLAGS -type f -name "*.$TARGET" -print0 | while IFS= read -r -d '' file; do
    # Strip the old extension and append the new one
    new_name="${file%.$TARGET}.$REPLACE"

    echo "Renaming '$file' -> '$new_name'"
    mv "$file" "$new_name"
done

echo "Process complete."
