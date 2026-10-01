#!/usr/bin/env bash
#
# Resize one image so its shortest side is a given number of pixels, writing the
# result beside the input and keeping the input's own codec.
#
#   img-resize-1080.sh example.jpg   ->   example-1080.jpg
#   img-resize.sh example.jpg 1080   ->   example-1080.jpg
#
# img-resize-1080.sh, -1440 and -2160 are this script with the size filled in.
# They hold no logic, so the arithmetic and the output naming exist once. Use
# img-resize.sh directly for a size that is not one of those three.
#
# The output extension is copied from the input, so the codec is preserved by
# construction and there is no format argument here. For changing codec, see
# img-convert.sh.
#
# Metadata is carried through, and there is no --strip.
#
# Needs libvips. `img-resize.sh --doctor` reports what this build can do, and
# how it reads the Exif orientation that this path depends on.

set -euo pipefail

IL_LIB_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
if [[ ! -r $IL_LIB_DIR/image-lib.sh ]]; then
	printf '%s: cannot find image-lib.sh next to %s\n' \
		"$(basename -- "$0")" "$0" >&2
	exit 1
fi
# shellcheck source=image-lib.sh
source "$IL_LIB_DIR/image-lib.sh"

usage() {
	# The parts of this help that depend on how the tool was called. A wrapper
	# already has its size, so it takes one argument and refuses a second; the
	# direct form takes the size, and says so in every example below.
	local usage_line="$IL_PROG [OPTIONS] <input> <size>"
	local batch="$IL_PROG {} 1080 +"
	local any_size='img-resize.sh'
	local size_word=' 1200'
	local overwrite="$IL_PROG -o holiday.jpg 1080"

	# Printed outside the heredoc below, because a multi-line variable cannot
	# carry the heredoc's leading tabs with it: expansion happens after `<<-` has
	# already stripped them, so the second and later lines of a substituted
	# string keep whatever indentation they were written with.
	if [[ -n $IL_PINNED ]]; then
		usage_line="$IL_PROG [OPTIONS] <input>"
		batch="$IL_PROG {} +"
		any_size="$IL_PROG"
		size_word=''
		overwrite="$IL_PROG -o holiday.jpg"

		cat <<-EOF
			Usage: $usage_line

			Resize one image so its shortest side is $IL_PINNED, writing
			<stem>-$IL_PINNED.<ext> beside the input.

			This tool fixes the size and refuses any other, so that what its name
			says is what it does. For a size of your own choosing, use
			img-resize.sh <input> <size> instead.
		EOF
	else
		cat <<-EOF
			Usage: $usage_line

			Resize one image so its shortest side is the given number of pixels,
			writing <stem>-<size>.<ext> beside the input, in the input's directory.
		EOF
	fi

	cat <<-EOF

		Nothing is written when the shortest side is already smaller than the
		size: upscaling costs bytes and adds no detail. That is a skip, and it
		exits 0.

		A portrait photo is usually stored sideways with an Exif tag telling the
		viewer to turn it. Such an image is measured with its width and height
		swapped, because sizing against the stored dimensions would constrain
		the wrong axis and produce a sideways result. libvips applies the
		rotation while it resizes, so the output is upright.

		Supported formats: $(il_supported_formats). gif and tif are readable by
		libvips and are refused here. An image whose Exif orientation cannot be
		read is refused rather than resized blindly.

		Batch is left to the shell:
		  find . -name '*.jpg' -exec $batch

	$(il_help_options)
	EOF

	# A fixed-size wrapper has no size to offer, so it advertises neither the
	# --size option nor the examples that need one.
	if [[ -n $IL_PINNED ]]; then
		cat <<-EOF

			Examples:
		EOF
	else
		cat <<-EOF

			Tool-specific options:
			  --size <size>     The same size, as an option. Useful in a script.

			Examples:
			  # The three fixed sizes
			  img-resize-1080.sh holiday.jpg
			  img-resize-1440.sh holiday.jpg
			  img-resize-2160.sh holiday.jpg
		EOF
	fi

	cat <<-EOF

		  # A smaller AVIF while we are here
		  $any_size --quality 45 holiday.heic$size_word

		  # Replace a previous result
		  $overwrite

		  # Check what this libvips can do before relying on it
		  $IL_PROG --doctor
	EOF
}

if il_wants_help "$@"; then
	if (( IL_WANTS_VERSION )); then
		printf '%s %s\n' "$IL_PROG" "$IL_VERSION"
	else
		usage
	fi
	exit 0
fi

il_getopts "$@"

# Before anything is validated, so that `--doctor` on its own is the one
# command that works on a machine where nothing else does.
if (( IL_DOCTOR )); then
	il_doctor
	exit 0
fi

# Two positionals at most: the file, and the size if it was not given as an
# option. A fixed-size wrapper supplies IL_PINNED instead and passes its own
# arguments through untouched, so `img-resize-1080.sh -o a.jpg` does what it
# looks like.
POSITIONAL_SIZE=''
if (( ${#IL_ARGS[@]} == 2 )); then
	POSITIONAL_SIZE=${IL_ARGS[1]}
elif (( ${#IL_ARGS[@]} != 1 )); then
	usage >&2
	il_die "expected an input file and a size, got ${#IL_ARGS[@]} argument(s)"
fi

if [[ -n $IL_SIZE && -n $POSITIONAL_SIZE ]]; then
	il_die "the size was given twice: --size $IL_SIZE and $POSITIONAL_SIZE"
fi

# A wrapper's own size wins over both, and is the only thing that may be given
# at all. Accepting `img-resize-2160.sh photo.jpg 1080` and resizing to 1080
# would make the wrapper a lie; refusing it is the whole point of pinning the
# size rather than defaulting to it.
if [[ -n $IL_PINNED ]]; then
	if [[ -n $IL_SIZE ]]; then
		il_die "this tool fixes the size at $IL_PINNED, and --size asks for $IL_SIZE"
	fi
	if [[ -n $POSITIONAL_SIZE && $POSITIONAL_SIZE != "$IL_PINNED" ]]; then
		il_die "this tool fixes the size at $IL_PINNED, and $POSITIONAL_SIZE was
    given. Use img-resize.sh to choose a size."
	fi
	SIZE=$IL_PINNED
else
	SIZE=${IL_SIZE:-$POSITIONAL_SIZE}
fi

if [[ -z $SIZE ]]; then
	usage >&2
	il_die "a size is required, as an argument or with --size"
fi
if [[ ! $SIZE =~ ^[0-9]+$ ]] || (( 10#$SIZE <= 0 )); then
	il_die "a size is a number of pixels, got: $SIZE"
fi
# Normalised, so a size of 0080 does not write holiday-0080.jpg.
SIZE=$(( 10#$SIZE ))

INPUT=${IL_ARGS[0]}

if [[ ! -e $INPUT ]]; then
	il_die "no such file: $INPUT"
fi
if [[ ! -f $INPUT ]]; then
	il_die "not a file: $INPUT"
fi
if [[ ! -r $INPUT ]]; then
	il_die "cannot read: $INPUT"
fi

il_split_name "$INPUT"
if [[ -z $IL_EXT ]]; then
	il_die "$INPUT has no extension, so there is no way to tell what it is"
fi

# What the input is, which also decides what the output is: the codec is
# preserved by copying the extension rather than by converting.
INPUT_FORMAT=$(il_input_codec "$IL_EXT")

il_require_vips

OUT_DIR=${IL_DIR:+$IL_DIR/}
OUT="${OUT_DIR}${IL_STEM}-${SIZE}.${IL_EXT}"
il_refuse_if_exists "$OUT"

# Print one field of the image header, or fail. Bare value and `width: 4000`
# are both answers vipsheader gives, depending on the build, so the digits are
# taken out of whatever came back rather than assumed to be the whole of it.
read_header() {
	local field=$1 value=''

	value=$(vipsheader -f "$field" -- "$INPUT" 2>/dev/null) || value=''
	value=$(il_first_int "$value")
	if [[ ! $value =~ ^[0-9]+$ ]] || (( 10#$value <= 0 )); then
		return 1
	fi

	printf '%s' "$value"
}

if ! WIDTH=$(read_header width) || ! HEIGHT=$(read_header height); then
	il_fail "cannot read the dimensions of $INPUT with vipsheader"
fi

ORIENTATION=''
if ! ORIENTATION=$(il_orientation "$INPUT"); then
	il_fail "refusing to resize $INPUT without an orientation. --doctor reports how
    this build reads Exif orientation."
fi
if [[ ! $ORIENTATION =~ ^[1-8]$ ]]; then
	il_fail "unusable Exif orientation for $INPUT: $ORIENTATION"
fi

# The dimensions the image has when it is displayed, which are not always the
# dimensions it is stored with. Orientations 5 to 8 are the ones that turn by 90
# degrees; 2, 4 and 7 mirror, which changes nothing about the size.
STORED_W=$WIDTH
STORED_H=$HEIGHT
if (( ORIENTATION >= 5 )); then
	WIDTH=$HEIGHT
	HEIGHT=$STORED_W
fi

if (( WIDTH <= HEIGHT )); then
	SHORTEST=$WIDTH
else
	SHORTEST=$HEIGHT
fi

# A skip, not a failure. Enlarging an image to reach a size costs bytes and adds
# nothing a viewer can see, so there is nothing to do and nothing to report
# beyond why.
if (( SHORTEST < SIZE )); then
	printf 'skipped %s: shortest side is %d, already smaller than %d\n' \
		"$INPUT" "$SHORTEST" "$SIZE"
	exit "$IL_EX_OK"
fi

# Both target dimensions, from the corrected ones, in integer arithmetic.
#
# Integer maths is not an approximation here, it is the point: the result is the
# same on every machine, rather than depending on how a library rounds. The
# side that is not constrained is rounded to nearest, which is at most half a
# pixel out and never above the input, because the ratio is below one and the
# rounding is worth less than the pixel it can add.
if (( WIDTH <= HEIGHT )); then
	TARGET_W=$SIZE
	TARGET_H=$(( (HEIGHT * SIZE + WIDTH / 2) / WIDTH ))
else
	TARGET_H=$SIZE
	TARGET_W=$(( (WIDTH * SIZE + HEIGHT / 2) / HEIGHT ))
fi

if (( TARGET_W < 1 || TARGET_H < 1 )); then
	il_fail "$INPUT would resize to ${TARGET_W}x${TARGET_H}, which is not an image"
fi

if (( ORIENTATION != 1 )); then
	printf '%s has Exif orientation %d, so its stored %dx%d is measured as %dx%d\n' \
		"$INPUT" "$ORIENTATION" "$STORED_W" "$STORED_H" "$WIDTH" "$HEIGHT"
fi

# Somewhere nobody will look, in the directory the output belongs in so the mv
# below is a rename, and moved into place only once it is a whole image.
if ! TMP=$(il_temp_path "${IL_DIR:-.}" "$IL_EXT"); then
	il_fail "cannot create a temporary file in ${IL_DIR:-.}"
fi

# thumbnail rather than resize: it brings JPEG shrink-on-load with it, so a
# large JPEG is never fully decoded, and it applies the orientation itself.
# --size force makes it hit exactly the dimensions computed above instead of
# preserving the aspect ratio itself.
if ! reason=$(vips thumbnail "$INPUT" "$(il_save_name "$TMP" "$INPUT_FORMAT")" \
	"$TARGET_W" --height "$TARGET_H" --size force 2>&1 >/dev/null); then
	rm -f -- "$TMP"
	il_fail "vips could not resize $INPUT: $(il_first_line "$reason")"
fi

if ! il_verify_output "$TMP"; then
	rm -f -- "$TMP"
	il_fail "vips reported success but $OUT is not a readable image. --doctor says
    what this build can write."
fi

il_install_output "$TMP" "$OUT" "$INPUT"

printf 'resized %s %dx%d -> %s %dx%d\n' \
	"$INPUT" "$STORED_W" "$STORED_H" "$OUT" "$TARGET_W" "$TARGET_H"
