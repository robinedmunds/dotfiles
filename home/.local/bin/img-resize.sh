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

		A screenshot carries no orientation tag at all, because there is nothing
		to turn: that is settled from the file's own bytes rather than from a
		reader, and such a file is resized as it is stored. Only a file that
		does carry Exif which cannot be read is refused, because that is the
		case where the answer is not obvious from looking at the file.

		Supported formats: $(il_supported_formats). gif and tif are readable by
		libvips and are refused here.

		Batch is left to the shell:
		  find . -name '*.jpg' -exec $batch

	$(il_help_options)
	EOF

	# --size is the one option a wrapper has nothing to offer, so it is printed
	# only when there is a size to choose. --assume-upright is printed either
	# way: a wrapper is the tool people actually type, and an option its --help
	# does not mention is an option nobody finds.
	printf '\nResize options:\n'
	if [[ -z $IL_PINNED ]]; then
		printf '  --size <size>     The same size, as an option. Useful in a script.\n'
	fi
	cat <<-EOF
		  --assume-upright  Resize a file whose Exif orientation cannot be read,
		                   as though it carried no rotate-for-display tag. The
		                   pixels are left as stored and the tag goes through
		                   untouched, so a viewer still turns the result the
		                   right way up.
	EOF

	if [[ -n $IL_PINNED ]]; then
		cat <<-EOF

			Examples:
		EOF
	else
		cat <<-EOF

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

# The orientation and how it was settled come back as one string, because the
# read happens in a command substitution and a variable set in there would be set
# in the subshell and lost. Split here rather than in the library, so the decision
# about what the two fields mean is made next to the decision about what to do
# with them.
ORIENTATION=''
IL_ORIENTATION_KIND=''
if ORIENTATION=$(il_orientation "$INPUT" "$INPUT_FORMAT"); then
	IL_ORIENTATION_KIND=${ORIENTATION%% *}
	ORIENTATION=${ORIENTATION#* }
	if [[ ! $ORIENTATION =~ ^[1-8]$ ]]; then
		# Unreachable through il_orientation, which checks the range itself
		# before printing. Checked here because this is the one place the value
		# is used as a number, and a shell that read the field wrong would
		# otherwise get `(( ORIENTATION >= 5 ))` on an empty string.
		il_fail "unusable orientation for $INPUT: $ORIENTATION"
	fi
	elif (( IL_ASSUME_UPRIGHT )); then
	ORIENTATION=1
	IL_ORIENTATION_KIND='forced'
else
	# The library has already said why, on stderr. This is the consequence: a
	# file with an orientation nobody can read is not resized at all.
	il_fail "nothing has been written for $INPUT"
fi

# libvips applies the orientation itself while it resizes, which is what makes
# the output upright without a second pass over the file. That is only true
# while the two agree on what the orientation is, so where this script settled
# it without a reader -- no Exif in the file, or --assume-upright standing in
# for a tag nobody could read -- libvips is told not to rotate as well. An
# assumption and an action cannot then come to different answers, and in the
# second case the tag itself rides through untouched, so a viewer still turns the
# pixels the right way up.
NO_ROTATE=''
case $IL_ORIENTATION_KIND in
	none | forced) NO_ROTATE='--no-rotate' ;;
esac

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
# large JPEG is never fully decoded, and it applies the orientation itself,
# which is why --no-rotate above goes with the case where it must not.
# --size force makes it hit exactly the dimensions computed above instead of
# preserving the aspect ratio itself.
#
# $NO_ROTATE unquoted on purpose: it is one flag with no characters a glob or a
# word split could do anything with, and quoting it would pass an empty string
# to vips instead of leaving the argument out.
# shellcheck disable=SC2086
if ! reason=$(vips thumbnail "$INPUT" "$(il_save_name "$TMP" "$INPUT_FORMAT")" \
	"$TARGET_W" --height "$TARGET_H" --size force $NO_ROTATE 2>&1 >/dev/null); then
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
