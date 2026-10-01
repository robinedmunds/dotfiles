#!/bin/bash

# Check if correct number of arguments are provided
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <input_directory> <output_directory>"
    exit 1
fi

INPUT_DIR="$1"
OUTPUT_DIR="$2"

# Check if input directory exists
if [ ! -d "$INPUT_DIR" ]; then
    echo "Error: Input directory $INPUT_DIR does not exist."
    exit 1
fi

# Create output directory if it doesn't exist
mkdir -p "$OUTPUT_DIR"

echo "Replicating directory structure..."
# Find all directories in input and recreate them in output
find "$INPUT_DIR" -type d -printf "%P\0" | xargs -0 -I {} mkdir -p "$OUTPUT_DIR/{}"

echo "Converting PNG images to AVIF..."
# Find all .png files (case-insensitive)
find "$INPUT_DIR" -type f -iname "*.png" -print0 | while IFS= read -r -d '' file; do
    # Determine the relative path to maintain structure
    REL_PATH="${file#$INPUT_DIR/}"
    # Define the output path by changing extension to .avif
    DEST_PATH="$OUTPUT_DIR/${REL_PATH%.*}.avif"
    
    echo "Processing: $REL_PATH"
    
    # Use ImageMagick to convert
    # -quality 90: Sets the compression level
    # -define heic:preserve-orientation=true: Helps maintain EXIF orientation
    # By default, ImageMagick attempts to preserve profiles (EXIF, ICC, etc.) 
    # unless -strip is used.
    magick "$file" -quality 90 "$DEST_PATH"
done

echo "Processing complete."
