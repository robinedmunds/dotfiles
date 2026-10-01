#!/bin/bash

# Check if correct number of arguments are provided
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <input_directory> <output_directory>"
    exit 1
fi

INPUT_DIR=$(realpath "$1")
OUTPUT_DIR=$(realpath "$2")

# Check if input directory exists
if [ ! -d "$INPUT_DIR" ]; then
    echo "Error: Input directory $INPUT_DIR does not exist."
    exit 1
fi

# Create output directory if it doesn't exist
mkdir -p "$OUTPUT_DIR"

echo "Replicating directory structure..."
find "$INPUT_DIR" -type d -printf "%P\0" | xargs -0 -I {} mkdir -p "$OUTPUT_DIR/{}"

echo "Converting PNG images to AVIF in parallel..."

# Export variables and the function so xargs can access them
export INPUT_DIR
export OUTPUT_DIR

process_image() {
    local file="$1"
    # Determine the relative path
    local rel_path="${file#$INPUT_DIR/}"
    # Define the output path by changing extension to .avif
    local dest_path="$OUTPUT_DIR/${rel_path%.*}.avif"

    echo "Processing: $rel_path"

    # Use ImageMagick to convert
    # -quality 90: Sets the compression level
    nice -n 19 magick "$file" -quality 90 "$dest_path" && touch -r "$file" "$dest_path"
}

export -f process_image

# Find all .png files and pipe to xargs
# -P 0 tells xargs to run as many processes as possible (usually CPU count)
# -n 1 ensures one file is passed to each function call
find "$INPUT_DIR" -type f -iname "*.png" -print0 | xargs -0 -n 1 -P 24 bash -c 'process_image "$0"'

echo "Processing complete."
