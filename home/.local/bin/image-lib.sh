#!/usr/bin/env bash
#
# Shared helpers for the img-* image tools.
#
# Sourced, never executed, which is why this file is 644 and not 755. Every
# tool that uses it resolves it relative to its own location, so the family
# works identically from the Repository and from Home.
#
# What lives here, and why:
#
#   * Backend detection. libvips is the only backend and there is no fallback.
#     A build that cannot write a format is reported, not quietly worked
#     around, because a second encoder underneath makes output unpredictable.
#   * The format table. What can be read, what can be written, what the output
#     extension is, and which save options each saver takes. One table, so a
#     tool cannot disagree with --doctor about what exists.
#   * Quality. libvips runs quality backwards from ImageMagick, so the default
#     and the warning about it are written once.
#   * --doctor, which probes every output format with a real 16x16 encode. An
#     operation listing does not tell you whether an encoder is present behind
#     a saver: a libvips can list heifsave and still have no AV1 encoder, which
#     is why reading AVIF and writing it are separate questions.
#
# Nothing here writes to stdout except the functions documented as printing.

# Sourcing twice must not re-run the declarations below.
if [[ -n ${IL_LIB_LOADED:-} ]]; then
	return 0
fi
IL_LIB_LOADED=1

# Bumped when the shared interface changes in a way that breaks a caller.
IL_VERSION='1'

# Exit codes, shared so a caller can branch on the outcome without knowing which
# tool it invoked. A usage problem and a runtime failure are kept apart because
# they ask different things of the caller: one is "you called me wrong", the
# other is "something went wrong while I was working".
IL_EX_OK=0
IL_EX_FAILED=1
IL_EX_USAGE=2

# The name diagnostics are prefixed with. img-resize-<N>.sh sets IL_PROG_NAME
# before exec'ing img-resize.sh, so the messages name the tool that was typed
# rather than the one that did the work.
: "${IL_PROG_NAME:=}"
if [[ -n $IL_PROG_NAME ]]; then
	IL_PROG=$IL_PROG_NAME
else
	IL_PROG=$(basename -- "$0")
fi

# The size a fixed-size wrapper has already fixed, set in the environment before
# it execs img-resize.sh. Empty when img-resize.sh was called directly and has
# to be told the size.
: "${IL_PINNED:=}"

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------

il_warn() {
	printf '%s: %s\n' "$IL_PROG" "$*" >&2
}

# Report a usage problem and stop with IL_EX_USAGE. A missing dependency is a
# usage problem too: the tool cannot do what it was asked, and no amount of
# retrying will change that.
il_die() {
	il_warn "$*"
	exit "$IL_EX_USAGE"
}

# Report a failure part way through the work and stop with IL_EX_FAILED.
il_fail() {
	il_warn "$*"
	exit "$IL_EX_FAILED"
}

il_require_cmd() {
	if ! command -v "$1" >/dev/null 2>&1; then
		il_die "$1 is required, but is not installed"
	fi
}

# libvips is the only backend. Both commands are needed: vipsheader reads the
# dimensions and the orientation, vips does the work.
il_require_vips() {
	il_require_cmd vips
	il_require_cmd vipsheader
}

# Print the first run of digits in the argument.
#
# vipsheader -f orientation answers with `orientation: 6 (rotate 90 CW)` on
# some builds and a bare `6` on others, and exiftool adds a trailing newline.
# Both are read here so one build's wording does not become another's failure.
il_first_int() {
	local text=$1

	if [[ $text =~ ([0-9]+) ]]; then
		printf '%s' "${BASH_REMATCH[1]}"
	fi
}

# Print the first line of the argument, so a multi-line libvips error can be
# quoted in a single-line report.
il_first_line() {
	local text=$1

	text=${text%%$'\n'*}
	printf '%s' "$text"
}

# ---------------------------------------------------------------------------
# The format table
# ---------------------------------------------------------------------------

# Formats these tools handle, in the order they are reported by --doctor.
#
# gif and tif are deliberately absent. libvips reads both, so a tool built on it
# could handle them, but the output of one of them is either a single frame
# (silently dropping the rest of an animation) or a set of pages, and neither is
# what somebody asking for a conversion is expecting.
IL_FORMATS=(jpeg png webp avif heic)

# Input extensions, and so the extensions that name a codec on the way in. A
# JPEG may be written either way, which is why this is not IL_FORMATS.
IL_INPUT_EXT=(jpg jpeg png webp avif heic)

# The saver operation for each format. jpeg is jpegsave, not jpegsave's shorter
# spelling, and both AVIF and HEIC go through heifsave with a different
# compression.
declare -gA IL_SAVER=(
	[jpeg]=jpegsave
	[png]=pngsave
	[webp]=webpsave
	[avif]=heifsave
	[heic]=heifsave
)

# The loader operation for each format. heifload covers AVIF and HEIC alike:
# both are containers that libvips reads with one loader, which is why the
# write side has to be probed rather than read off this table.
declare -gA IL_LOADER=(
	[jpeg]=jpegload
	[png]=pngload
	[webp]=webpload
	[avif]=heifload
	[heic]=heifload
)

# The extension an output of this format is given. jpeg is the one format whose
# name and extension differ, so a conversion to jpeg writes .jpg.
declare -gA IL_OUT_EXT=(
	[jpeg]=jpg
	[png]=png
	[webp]=webp
	[avif]=avif
	[heic]=heic
)

# 1 when the format is lossy and --quality means something, 0 when it is
# lossless and does not.
declare -gA IL_LOSSY=(
	[jpeg]=1
	[png]=0
	[webp]=1
	[avif]=1
	[heic]=1
)

# The HEIF compression each of the two containers is written with.
#
# These are passed explicitly rather than left to the file suffix. Left alone,
# heifsave defaults to HEVC whatever the output is called, and a file named
# .avif holding an HEVC bitstream is worse than a failed conversion: it looks
# right and is not.
declare -gA IL_COMPRESSION=(
	[avif]=av1
	[heic]=hevc
)

# libvips quality: 0 is best, 100 is worst. 90 is near-transparent for JPEG and
# WebP and a very large file for AVIF, which is usually indistinguishable from
# 45. The default stays at 90 so the same number means the same thing across
# formats; --doctor says so out loud.
IL_DEFAULT_QUALITY=90

# Print the supported formats for a refusal message: "jpeg, png, webp, avif,
# heic". Comma and space separated, because this is read by a person deciding
# what to type next, not parsed by anything.
il_supported_formats() {
	local out='' format

	for format in "${IL_FORMATS[@]}"; do
		out+="${out:+, }$format"
	done

	printf '%s' "$out"
}

# Print the supported input extensions, space separated, for a refusal message.
il_supported_exts() {
	printf '.%s ' "${IL_INPUT_EXT[@]}"
}

# Normalise a target format name: lowercase, no leading dot, aliases folded in.
# So "webp", ".webp" and "WebP" are the same request, and so are "jpg" and
# "jpeg". Prints the canonical name, or dies listing what is supported.
#
# An unknown format is refused rather than guessed at: writing a .tiff with a
# webp encoder in it would be a file that lies about its own contents.
il_normalise_format() {
	local fmt=${1#.}

	fmt=${fmt,,}
	case $fmt in
		jpg | jpeg) fmt=jpeg ;;
		png | webp | avif | heic) ;;
		'')
			il_die "a format is required"
			;;
		*)
			il_die "unknown format: $1 (supported: $(il_supported_formats))"
			;;
	esac

	printf '%s' "$fmt"
}

# Print the codec an input file's extension names, or die.
#
# Separate from il_normalise_format because the failure is about a file rather
# than a request, and because gif and tif get an explanation of their own: they
# are readable by libvips, so "unknown format" would be the wrong story.
il_input_codec() {
	local ext=${1#.}

	ext=${ext,,}
	if [[ $ext == gif || $ext == tif || $ext == tiff ]]; then
		il_die "$ext is readable by libvips and is left out on purpose: these tools read $(il_supported_exts)"
	fi

	il_normalise_format "$ext"
}

# Print the saver operation for a format.
il_saver() {
	printf '%s' "${IL_SAVER[$1]}"
}

# Print the save options for a format, in the `name=value,name=value` form
# libvips reads off the end of a filename. Prints nothing for a format that
# takes no options.
#
# Quality is passed straight through, which is only safe because the direction is
# the libvips one: `--quality 45` here is 45 for libvips, which is very good.
# Anyone arriving with an ImageMagick `-q 90` habit is asking for the worst
# setting available, and the usage message says so before that happens.
il_save_options() {
	local format=$1 quality='' compression='' opts=()

	if [[ -n $IL_QUALITY ]]; then
		if [[ ${IL_LOSSY[$format]:-0} == 0 ]]; then
			# Say so, and drop the option. Passing Q to a lossless saver is
			# not a smaller file, it is an option that saver does not have,
			# and libvips reports that as an unknown-parameter error.
			il_warn "$format is lossless, so --quality $IL_QUALITY is ignored"
			quality=''
		else
			quality=$IL_QUALITY
		fi
	elif [[ ${IL_LOSSY[$format]:-0} == 1 ]]; then
		quality=$IL_DEFAULT_QUALITY
	fi

	compression=${IL_COMPRESSION[$format]:-}
	if [[ -n $compression ]]; then
		opts+=("compression=$compression")
	fi
	if [[ -n $quality ]]; then
		opts+=("Q=$quality")
	fi

	if (( ${#opts[@]} == 0 )); then
		return 0
	fi

	local IFS=,
	printf '%s' "${opts[*]}"
}

# Print the output filename argument for vips, save options attached.
#
# `filename[name=value]` is the only way to pass save options on the command
# line, so the two have to be built together or the options are lost.
il_save_name() {
	local path=$1 options

	options=$(il_save_options "$2")
	if [[ -n $options ]]; then
		printf '%s[%s]' "$path" "$options"
	else
		printf '%s' "$path"
	fi
}

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------

# True if the arguments ask for help or the version. Scans the whole list, so
# `--quality 90 --help` prints help rather than complaining about --help.
il_wants_help() {
	local arg

	IL_WANTS_VERSION=0
	for arg in "$@"; do
		case $arg in
			-h | --help)
				return 0
				;;
			-V | --version)
				IL_WANTS_VERSION=1
				return 0
				;;
		esac
	done

	return 1
}

# Parse the options the img-* tools share.
#
# The positional arguments left over come back in IL_ARGS, not in "$@". A
# function cannot rewrite its caller's positional parameters: shifting inside
# here is forgotten the moment it returns, so the caller would go on to count
# its own options as arguments.
il_getopts() {
	IL_OVERWRITE=0
	IL_DOCTOR=0
	IL_QUALITY=''
	IL_SIZE=''
	IL_ASSUME_UPRIGHT=0
	IL_ARGS=()

	while (( $# )); do
		case $1 in
			-o | --overwrite)
				IL_OVERWRITE=1
				;;
			--quality)
				if (( $# < 2 )); then
					il_die "--quality needs a number"
				fi
				IL_QUALITY=$2
				shift
				;;
			--quality=*)
				IL_QUALITY=${1#--quality=}
				;;
			--size)
				if (( $# < 2 )); then
					il_die "--size needs a number"
				fi
				IL_SIZE=$2
				shift
				;;
			--size=*)
				IL_SIZE=${1#--size=}
				;;
			--doctor)
				IL_DOCTOR=1
				;;
			--assume-upright)
				IL_ASSUME_UPRIGHT=1
				;;
			--)
				shift
				IL_ARGS+=("$@")
				break
				;;
			-?*)
				il_die "unknown option: $1 (try --help)"
				;;
			*)
				IL_ARGS+=("$1")
				;;
		esac
		# One step per iteration. Branches that consume a value of their own
		# shift once more before falling through to here.
		shift
	done

	il_check_quality
}

# Reject a --quality that is not a number from 0 to 100, now rather than after
# an encode has been started.
il_check_quality() {
	if [[ -z $IL_QUALITY ]]; then
		return 0
	fi
	if [[ ! $IL_QUALITY =~ ^[0-9]+$ ]]; then
		il_die "--quality takes a number from 0 to 100, got: $IL_QUALITY"
	fi
	# 10# so that 090 means ninety rather than being read as octal, and an
	# empty string is a syntax error in arithmetic.
	if (( 10#$IL_QUALITY > 100 )); then
		il_die "--quality is 0 to 100, got: $IL_QUALITY"
	fi
	# Back to a plain decimal, so what is handed to libvips is `Q=90` and not
	# `Q=090`. A leading zero in a save option is a different spelling of the
	# same number, and one that some builds read as octal.
	IL_QUALITY=$(( 10#$IL_QUALITY ))
}

# Print the help block shared by both tools. Each supplies its own usage line,
# description and examples around it.
il_help_options() {
	cat <<-'EOF'
		Options:
		  -o, --overwrite    Replace the output file if it is already there.
		                       Off by default: a conversion that overwrites is
		                       a conversion that destroyed something.
		      --quality N    Save quality, 0 to 100. Default 90.
		                       libvips runs quality the opposite way round from
		                       ImageMagick: 0 is best, 100 is worst, so this is
		                       not a -q 90 carried over from `magick`. Ignored
		                       for png, which is lossless.
		      --doctor       Report what this libvips can read and write, and
		                       stop. Works with no other arguments.
		  -h, --help         Print this help and exit.
		  -V, --version      Print the version and exit.

		Exit codes:
		  0  Done, or nothing to do.
		  1  Runtime failure.
		  2  Usage error: bad arguments, a missing file, an unsupported
		     format, or an output that already exists.
	EOF
}

# ---------------------------------------------------------------------------
# Running vips
# ---------------------------------------------------------------------------

il_vips_version() {
	local version

	version=$(vips --version 2>/dev/null) || version=''
	version=${version#vips-}
	printf '%s' "${version:-unknown}"
}

# Print how many cores libvips will use.
#
# libvips is multithreaded and uses every core, so a batch over these tools must
# not add -P on top: that is the reason the tools have no parallel mode of their
# own, and the reason this number is worth reporting.
il_core_count() {
	local cores=''

	if cores=$(nproc 2>/dev/null) && [[ $cores =~ ^[0-9]+$ ]]; then
		printf '%s' "$cores"
		return 0
	fi
	if cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null) && [[ $cores =~ ^[0-9]+$ ]]; then
		printf '%s' "$cores"
		return 0
	fi
	if cores=$(sysctl -n hw.ncpu 2>/dev/null) && [[ $cores =~ ^[0-9]+$ ]]; then
		printf '%s' "$cores"
		return 0
	fi

	printf 'unknown'
}

# The operation listing, fetched once. It is only ever used as a hint about what
# a build offers; nothing that decides an outcome is read out of it.
IL_OPS=''
il_ops() {
	if [[ -z $IL_OPS ]]; then
		IL_OPS=$(vips -l 2>/dev/null) || IL_OPS=''
	fi
	printf '%s' "$IL_OPS"
}

# True if this build lists an operation.
il_has_op() {
	[[ -n ${1:-} ]] || return 1
	grep -qE "^[[:space:]]*$1[[:space:]]" <<<"$(il_ops)"
}

# Prove a file that was just written is one vips can read, and is not empty.
#
# A vips call that exits 0 has usually done the work, but a build with a broken
# encoder behind a saver can exit 0 and write nothing useful, and announcing a
# conversion that did not happen is worse than reporting a failure.
il_verify_output() {
	if [[ ! -s $1 ]]; then
		return 1
	fi

	vipsheader -f width -- "$1" >/dev/null 2>&1
}

# The reason the last il_probe_write failed, or empty if it did not fail.
IL_PROBE_ERROR=''

# Try to write a 16x16 image in FORMAT inside DIR, and say why if it cannot be
# written. Returns 0 if the encode worked.
#
# 16x16 is the smallest image worth encoding and it goes through the whole path:
# the saver, the encoder behind the saver, and a read back of the result. The
# operation listing cannot answer this, because whether an AV1 or HEVC encoder
# is present depends on how libheif was built, and a build that cannot encode
# still lists heifsave quite happily.
#
# The temporary files are removed on every path, including the failing ones: a
# --doctor run that leaves .avif files behind in the working directory is worse
# than one that says nothing.
il_probe_write() {
	local format=$1 dir=$2 base out reason

	IL_PROBE_ERROR=''

	if ! base=$(il_temp_path "$dir" ""); then
		IL_PROBE_ERROR="cannot write a temporary file in $dir"
		return 1
	fi
	out="$base.${IL_OUT_EXT[$format]}"

	if ! reason=$(vips black "$base.v" 16 16 --bands 3 2>&1 >/dev/null); then
		IL_PROBE_ERROR=$(il_first_line "${reason:-vips black failed}")
		rm -f -- "$base" "$base.v" "$out"
		return 1
	fi

	# The same call the tools make, options and all, so what the probe proves
	# is what the tools can do.
	if ! reason=$(vips "$(il_saver "$format")" "$base.v" \
		"$(il_save_name "$out" "$format")" 2>&1 >/dev/null); then
		IL_PROBE_ERROR=$(il_first_line "${reason:-the save failed}")
		rm -f -- "$base" "$base.v" "$out"
		return 1
	fi

	if ! il_verify_output "$out"; then
		IL_PROBE_ERROR="the encode reported success but wrote nothing readable"
		rm -f -- "$base" "$base.v" "$out"
		return 1
	fi

	rm -f -- "$base" "$base.v" "$out"
	return 0
}

# True if this build can read the orientation of a file, as far as it can be
# told without a photo in front of it.
#
# A generated file of either format carries no Exif, so a build that answers
# with a plain 1 is showing that the field is exposed at all. Both a JPEG and a
# PNG are asked, because a build can answer for one and not the other, and a
# desktop screenshot is a PNG: a doctor that only asked about JPEGs cannot see a
# failure that is specific to the file people most often resize.
#
# A build that does not answer gets IL_ORIENTATION_ERROR saying so, which is the
# case the exiftool fallback is for.
IL_ORIENTATION_ERROR=''
il_probe_orientation() {
	local dir=$1 ext=$2 probe reason

	IL_ORIENTATION_ERROR=''
	# The probe filename carries the format as its extension, because libvips
	# picks its loader from the extension and a .png asked for a JPEG's loader
	# would not test the JPEG's reader.
	probe="$dir/.img-probe-orientation.$ext"

	if ! reason=$(vips black "$probe" 16 16 --bands 3 2>&1 >/dev/null); then
		IL_ORIENTATION_ERROR="cannot make a test image: $(il_first_line "$reason")"
		rm -f -- "$probe"
		return 1
	fi

	# A command that fails without saying why is its own kind of problem, and
	# printing a bare "no" beside no reason leaves the reader with nothing to go
	# on. A few words cost nothing and say what happened.
	if ! reason=$(vipsheader -f orientation -- "$probe" 2>&1 >/dev/null); then
		reason=$(il_first_line "$reason")
		IL_ORIENTATION_ERROR=${reason:-'it exits non-zero and says nothing on stderr'}
		rm -f -- "$probe"
		return 1
	fi

	rm -f -- "$probe"
	return 0
}

# ---------------------------------------------------------------------------
# Orientation
# ---------------------------------------------------------------------------

# How a file's orientation was settled, which the caller needs to know because
# only one of these may be applied by libvips on its own:
#
#   read    a reader gave the value, and libvips will apply that same tag itself
#   none    the file carries no Exif, so there is nothing for libvips to apply
#           either, and it is told so rather than left to work it out again
#   forced  --assume-upright stood in for a tag no reader could read; the
#           pixels are left as stored and the tag goes through untouched
#
# Set by il_orientation, through il_orientation_result below, and kept only for
# the length of the call. A caller cannot read it afterwards, because a function
# that prints the orientation is nearly always called as `VAR=$(...)` and the
# assignment would happen in the subshell, where a variable set inside is set and
# then forgotten. Printing it is the way out of that.
IL_ORIENTATION_KIND=''

# Print "<kind> <orientation>" for the call that just read one.
#
# A caller that captured the orientation with `ORIENTATION=$(il_orientation ...)`
# has the kind too, in the same string, and splits the two fields for itself.
# Returning both at once is what makes the pair survive a subshell, and leaving
# the split to the caller keeps the reading of the two fields next to the decision
# about what they mean, rather than behind a convention in here.
il_orientation_result() {
	IL_ORIENTATION_KIND=${2:-}
	printf '%s %s' "$IL_ORIENTATION_KIND" "${1:-}"
}

# True when a format keeps its rotation outside Exif, so that the absence of
# Exif in the file says nothing about there being a rotate-for-display tag.
#
# HEIF and AVIF are both read through one loader, and both carry orientation in
# transformation boxes of their own rather than in Exif, so searching a HEIF
# file for Exif is a search for something that is never there. Those two always
# go to a reader.
il_orientation_is_intrinsic() {
	case ${1:-} in
		heic | avif) return 0 ;;
	esac

	return 1
}

# True when FILE carries Exif, decided from its own bytes rather than by asking
# a reader anything.
#
# This is the question the whole orientation path turns on, and a reader cannot
# answer it: libvips carries the Exif slot on every image it loads, so asking it
# whether there is Exif data reports on the image rather than on the tag in it.
# An absent tag and an unreadable one come back the same way, which put every
# file with no rotate-for-display tag at all -- every screenshot -- in the same
# class as a photograph whose Exif cannot be parsed, and refused both.
#
# All three Exif containers are searched in every file, whatever the file is
# called, so a JPEG carrying Exif under the wrong suffix is still recognised as
# carrying it.
#
# The search errs towards yes. A false yes costs one more question of a reader,
# which is the behaviour this path had before; a false no costs a sideways
# photograph. A false yes is possible where the bytes are picture data rather
# than a declared name -- deflate output can contain eXIf by chance -- and
# ruling it out would mean parsing the PNG chunk table to read one field.
il_has_exif() {
	local file=$1

	# grep is already wanted by --doctor, so this is not a new dependency. Its
	# absence is taken as Exif present rather than absent, because that is the
	# direction in which the answer is a sideways photograph rather than a
	# question asked of a reader that is not there.
	command -v grep >/dev/null 2>&1 || return 0

	LC_ALL=C grep -a -q -F -e Exif -e eXIf -e EXIF -- "$file" 2>/dev/null
}

# Print the EXIF orientation of FILE, from 1 to 8, or 1 for a file that carries
# no orientation in it, as "<kind> <orientation>" -- see il_orientation_result for
# why the kind travels back with the value rather than in a variable.
#
# A file with no Exif has an orientation of 1 by definition, and that is settled
# here from the bytes (see il_has_exif) rather than from a reader, which is also
# why no reader is run for one: most of what these tools get pointed at is
# screenshots, and a reader consulted about every one of them would be two
# processes spent to learn that a file is what it plainly is.
#
# A file with Exif in it that no reader could read is refused rather than guessed
# at, because sizing against the stored dimensions of a photograph that is meant
# to be turned constrains the wrong axis and produces a sideways result.
#
# The order is libvips first and exiftool second, because libvips is the backend
# these tools already need and exiftool may not be installed at all. What either
# of them answers is checked before it is returned, so a build whose reader
# answers with something that is not an orientation is refused rather than
# believed.
#
# Prints "<kind> <orientation>", or warns why it cannot and returns 1. It does
# not exit: a caller reaches this inside a command substitution, where an exit
# would leave the subshell and not the tool.
il_orientation() {
	local file=$1 format=${2:-} value='' raw=''

	if ! il_orientation_is_intrinsic "$format" && ! il_has_exif "$file"; then
		il_orientation_result 1 none
		return 0
	fi

	if value=$(vipsheader -f orientation -- "$file" 2>/dev/null); then
		value=$(il_first_int "$value")
		if [[ $value =~ ^[1-8]$ ]]; then
			il_orientation_result "$value" read
			return 0
		fi
		raw=${raw:-$value}
	fi

	# exiftool is a Perl script with its own idea of what an option is, so it
	# gets no `--` to end them: the path is passed as it arrived. It exits 0 on
	# a file with no Orientation tag at all, printing nothing, which is why an
	# empty answer is not an answer.
	if command -v exiftool >/dev/null 2>&1; then
		if value=$(exiftool -n -s3 -Orientation "$file" 2>/dev/null); then
			value=$(il_first_int "$value")
			if [[ $value =~ ^[1-8]$ ]]; then
				il_orientation_result "$value" read
				return 0
			fi
			raw=${raw:-$value}
		fi
	fi

	# Two failures that need different things done about them on the machine
	# this ran on, so they are not reported as one. A reader that answered with
	# something else answered *something*, which is a different problem from a
	# reader that answered nothing at all.
	if [[ -n $raw ]]; then
		il_warn "cannot use the orientation of $file: a reader answered '$raw', which
    is not an orientation from 1 to 8. Nothing has been written."
		return 1
	fi

	il_warn "cannot read the orientation of $file, and this file carries Exif.
    Resizing it without knowing how it is meant to be displayed can produce a
    sideways image, so nothing has been written. --assume-upright resizes it as
    it is stored instead."
	return 1
}

# ---------------------------------------------------------------------------
# Names and paths
# ---------------------------------------------------------------------------

# Split PATH into IL_DIR, IL_STEM and IL_EXT. IL_EXT carries no leading dot and
# is empty when the name has none.
#
# A leading dot marks a hidden file rather than a separator, so the search for
# the extension starts after it: `.cover.png` is a hidden file called
# `cover.png`, and is resized to `.cover-1080.png` rather than to `.png`.
il_split_name() {
	local path=$1 base body

	IL_DIR=$(dirname -- "$path")
	if [[ $IL_DIR == "." ]]; then
		IL_DIR=""
	fi

	base=$(basename -- "$path")
	if [[ $base == .?* ]]; then
		body=${base#.}
	else
		body=$base
	fi

	# A trailing dot has nothing after it, so it is not an extension either.
	if [[ $body == *.* && $body != *. ]]; then
		IL_EXT=${body##*.}
		IL_STEM="${base%.*}"
	else
		IL_EXT=""
		IL_STEM=$base
	fi
}

# Print a path in DIR that nothing else has used and that ends in EXT. Fails if
# no such path can be made.
#
# mktemp's template has to end in its run of Xs, and the extension cannot be
# added after them: both GNU mktemp and BusyBox mktemp reject a template that
# ends in anything else. So the name is made first and the extension added by
# renaming. The extension is not decoration — libvips picks its saver from the
# name it is given, and a temp file called .img-tmp.4fB2 would be written as a
# raw image rather than a JPEG.
#
# This is why the temporary file is made in the destination directory: it has to
# be there for the mv at the end to be a rename, and for the same filesystem
# the output belongs on.
il_temp_path() {
	local dir=$1 ext=$2 base

	if ! base=$(mktemp -- "$dir/.img-tmp.XXXXXXXX" 2>/dev/null); then
		return 1
	fi
	if [[ -n $ext ]] && ! mv -- "$base" "$base.$ext" 2>/dev/null; then
		rm -f -- "$base"
		return 1
	fi

	printf '%s' "${base}${ext:+.$ext}"
}

# Refuse to replace a file that is already there, unless --overwrite was given.
il_refuse_if_exists() {
	local dest=$1

	if [[ ! -e $dest ]]; then
		return 0
	fi
	if (( IL_OVERWRITE )); then
		return 0
	fi

	il_die "refusing to overwrite $dest (give -o to replace it)"
}

# Move a finished temporary file into place, optionally keeping SRC's timestamps.
#
# -f, not -n: whether to replace an existing file was decided once, before any
# encoding started, and a second decision here would either silently keep a stale
# file or silently destroy one.
il_install_output() {
	local tmp=$1 dest=$2 src=${3-}

	if ! mv -f -- "$tmp" "$dest"; then
		rm -f -- "$tmp"
		il_fail "wrote the image but could not move it into place: $dest"
	fi

	# So the resized file sorts next to the one it came from, in a directory
	# of photos kept in capture order by mtime.
	if [[ -n $src ]] && ! touch -r "$src" "$dest" 2>/dev/null; then
		il_warn "could not copy the modification time from $src"
	fi
}

# ---------------------------------------------------------------------------
# Doctor
# ---------------------------------------------------------------------------

# Report what this libvips can do, and stop.
#
# Called from either tool, before anything is validated, so it works with no
# other arguments on the line.
il_doctor() {
	local format write read_ok failures=0 tmpdir jpeg_orientation png_orientation

	if ! command -v vips >/dev/null 2>&1; then
		printf '%s: libvips is not installed, so there is nothing to report.\n' \
			"$IL_PROG" >&2
		printf 'These tools are thin wrappers over the vips command. On Arch: pacman -S libvips\n' >&2
		exit "$IL_EX_USAGE"
	fi
	if ! command -v vipsheader >/dev/null 2>&1; then
		printf '%s: vipsheader is not installed; these tools cannot read dimensions.\n' \
			"$IL_PROG" >&2
		exit "$IL_EX_USAGE"
	fi

	# The probes write files, so they happen in a directory of their own that
	# goes away afterwards whatever else happens. The path is expanded into the
	# trap rather than into a later run of it: tmpdir is local to this
	# function, and the trap does not fire until the tool has returned from it.
	#
	# Quoted, because a path is a path and a space in TMPDIR is not a word
	# separator here.
	if ! tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/img-doctor.XXXXXXXX" 2>/dev/null); then
		il_fail "cannot make a temporary directory to probe in"
	fi
	trap "rm -rf -- '$tmpdir'" EXIT

	printf '%s: libvips doctor\n\n' "$IL_PROG"
	printf '  vips           %s  (%s)\n' "$(il_vips_version)" "$(command -v vips)"
	printf '  cores          %s, all of them. libvips is already multithreaded, so\n' "$(il_core_count)"
	printf '                 do not add xargs -P on top of these tools.\n'

	# Both formats are probed and reported apart, because a build can answer
	# for one and not the other, and that difference is the whole question here.
	printf '  orientation    A file with no Exif carries no rotate-for-display\n'
	printf '                 tag, so it is measured as stored and resized with\n'
	printf '                 --no-rotate. vipsheader -f orientation is asked of a\n'
	printf '                 file with no Exif, one format at a time, because a\n'
	printf '                 build can answer for one and not the other, and a\n'
	printf '                 screenshot is a png:\n'
	if il_probe_orientation "$tmpdir" jpeg; then
		jpeg_orientation='answers'
	else
		jpeg_orientation="no: $IL_ORIENTATION_ERROR"
	fi
	if il_probe_orientation "$tmpdir" png; then
		png_orientation='answers'
	else
		png_orientation="no: $IL_ORIENTATION_ERROR"
	fi
	printf '                   jpeg  %s\n' "$jpeg_orientation"
	printf '                   png   %s\n' "$png_orientation"

	if command -v exiftool >/dev/null 2>&1; then
		printf '                 exiftool is installed and reads Exif when\n'
		printf '                 vipsheader does not.\n'
	else
		printf '                 exiftool is not installed, so Exif that\n'
		printf '                 vipsheader cannot read cannot be read at all.\n'
	fi
	printf '                 A file carrying Exif that neither can read is refused\n'
	printf '                 rather than guessed at; --assume-upright resizes it as\n'
	printf '                 it is stored.\n'

	printf '\n'
	printf '  format   read   write\n'

	for format in "${IL_FORMATS[@]}"; do
		write='no'
		read_ok='no'
		if il_probe_write "$format" "$tmpdir"; then
			write='yes'
			# The probe read the file it had just written, so read and write
			# are both proven for this format.
			read_ok='yes'
		elif il_has_op "${IL_LOADER[$format]}"; then
			# Cannot be written, but there is a loader for it, so reading is
			# a claim about the operation list rather than a proven fact.
			read_ok='yes'
		fi

		printf '  %-7s %-6s %s\n' "$format" "$read_ok" "$write"

		if [[ $write == no ]]; then
			failures=$(( failures + 1 ))
			printf '           %s cannot be written on this build:\n' "$format"
			printf '             %s\n' "$IL_PROBE_ERROR"
		fi
	done

	printf '\n'
	printf '  Each write above is a real 16x16 encode, not an entry in the operation\n'
	printf '  list: a libvips can read AVIF and still have no AV1 encoder to write it\n'
	printf '  with, and only the encode tells the two apart.\n'
	printf '\n'
	printf '  gif and tif can be read by libvips and are refused by these tools.\n'
	printf '  Quality is libvips quality: 0 is best, 100 is worst. AVIF at the default\n'
	printf '  90 is usually a bigger file than the JPEG it came from; --quality 45 is\n'
	printf '  visually indistinguishable from it and a fraction of the size.\n'

	if (( failures )); then
		printf '\n  %d of the formats above cannot be written here.\n' "$failures"
	fi

	return 0
}
