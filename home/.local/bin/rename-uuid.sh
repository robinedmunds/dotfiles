#!/bin/bash

# Default values
TARGET_DIR="."
RECURSIVE=false
UUID_REGEX="^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"

usage() {
    echo "Usage: $(basename "$0") [OPTIONS] [DIRECTORY]"
    echo
    echo "Renames files in a directory to random UUIDs while preserving extensions."
    echo "Skips files that are already named with a valid UUID."
    echo
    echo "Options:"
    echo "  -r, --recursive  Search subdirectories recursively."
    echo "  -h, --help       Display this help message."
    echo
    echo "Arguments:"
    echo "  DIRECTORY        The directory to process (defaults to current directory)."
    exit 1
}

# Parse options
while [[ "$#" -gt 0 ]]; do
    case "$1" in
    -r | --recursive)
        RECURSIVE=true
        shift
        ;;
    -h | --help)
        usage
        ;;
    -*)
        echo "Unknown option: $1"
        usage
        ;;
    *)
        TARGET_DIR="$1"
        shift
        ;;
    esac
done

# Ensure target directory exists
if [[ ! -d "$TARGET_DIR" ]]; then
    echo "Error: Directory '$TARGET_DIR' does not exist."
    exit 1
fi

# Ensure uuidgen is installed
if ! command -v uuidgen &>/dev/null; then
    echo "Error: uuidgen is not installed. Please install it and try again."
    exit 1
fi

# Set find depth based on recursive flag
# -maxdepth 1 means current directory only
FIND_OPTS=""
if [[ "$RECURSIVE" = false ]]; then
    FIND_OPTS="-maxdepth 1"
fi

# Find files and process them
find "$TARGET_DIR" $FIND_OPTS -type f | while read -r FILE_PATH; do
    DIR=$(dirname "$FILE_PATH")
    FILENAME=$(basename "$FILE_PATH")
    EXT="${FILENAME##*.}"
    BASE="${FILENAME%.*}"

    # Handle files with no extension
    if [[ "$FILENAME" == "$BASE" ]]; then
        EXT=""
    fi

    # Check if the current filename (without extension) is already a UUID
    if [[ ${BASE,,} =~ $UUID_REGEX ]]; then
        continue
    fi

    # Generate a new lowercase UUID
    NEW_UUID=$(uuidgen | tr '[:upper:]' '[:lower:]')

    # Construct the new filename
    if [[ -n "$EXT" && "$FILENAME" != "$EXT" ]]; then
        NEW_FILENAME="${NEW_UUID}.${EXT}"
    else
        NEW_FILENAME="$NEW_UUID"
    fi

    # Perform the rename
    if mv -n "$FILE_PATH" "$DIR/$NEW_FILENAME"; then
        echo "Renamed: $FILENAME -> $NEW_FILENAME"
    fi
done
