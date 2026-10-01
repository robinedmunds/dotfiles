#!/bin/bash

# Directory to process (default is current directory)
TARGET_DIR="${1:-.}"

# Check if directory exists
if [[ ! -d "$TARGET_DIR" ]]; then
  echo "Error: $TARGET_DIR is not a directory."
  exit 1
fi

# Iterate through files in the target directory
find "$TARGET_DIR" -type f | while read -r FILE; do
  # Get directory, filename, and extension
  DIR=$(dirname "$FILE")
  BASE=$(basename "$FILE")
  EXT="${BASE##*.}"
  NAME="${BASE%.*}"

  # Handle files without extensions
  if [[ "$BASE" == "$EXT" ]]; then
    EXT_SUFFIX=""
  else
    EXT_SUFFIX=".$EXT"
  fi

  # Get modification time: %Y%m%d_%H%M%S_%3N (YearMonthDay_HourMinSec_Millis)
  # Note: %3N provides the first 3 digits of nanoseconds (milliseconds)
  NEW_NAME=$(date -r "$FILE" +"%Y%m%d_%H%M%S_%3N")

  # Construct the new path
  NEW_PATH="$DIR/$NEW_NAME$EXT_SUFFIX"

  # Avoid overwriting if a file with the same timestamp already exists
  if [[ -e "$NEW_PATH" ]]; then
    COUNTER=1
    while [[ -e "$DIR/${NEW_NAME}_${COUNTER}${EXT_SUFFIX}" ]]; do
      ((COUNTER++))
    done
    NEW_PATH="$DIR/${NEW_NAME}_${COUNTER}${EXT_SUFFIX}"
  fi

  # Rename the file
  mv "$FILE" "$NEW_PATH"
  echo "Renamed: $BASE -> $(basename "$NEW_PATH")"
done
