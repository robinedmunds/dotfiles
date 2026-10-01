#!/usr/bin/env bash
#
# Convert one image to another codec, writing the result beside the input.
#
#   img-convert.sh example.png webp   ->   example.webp
#   img-convert.sh example.png jpeg   ->   example.jpg
#
# One file per invocation. Batch is left to the shell, which is better at it
# than a directory mode would be:
#
#   find . -name '*.png' -exec img-convert.sh {} webp +
#
# Metadata is carried through, and there is no --strip.
#
# Needs libvips. `img-convert.sh --doctor` reports what this build can write,
# which is worth running once: a libvips can read AVIF and still have no AV1
# encoder to write it with.

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
	cat <<-EOF
		Usage: $IL_PROG [OPTIONS] <input> <format>

		Convert one image to another codec. The output is named after the input
		with the format's extension, in the input's own directory:
		example.png to webp writes example.webp, and to jpeg writes example.jpg.

		The format is checked against a fixed table, so a misspelling is an
		error rather than a guess. A leading dot and capital letters are
		accepted: webp, .webp and WebP all mean the same thing, and so do jpg
		and jpeg.

		A conversion that would not change the codec is refused. A png to png
		conversion is a re-encode that loses information and produces a bigger
		file, and it is nearly always a mistyped command. For changing size
		instead of codec, see img-resize.sh.

		Supported formats: $(il_supported_formats). gif and tif are readable by
		libvips and are refused here: one of them is a single frame taken from
		an animation and the other is a stack of pages, and neither is what
		asking for a conversion means.

	$(il_help_options)

		Examples:
		  # One image, one conversion
		  $IL_PROG example.png webp

		  # AVIF at 45 rather than the default 90, which is usually
		  # indistinguishable from 90 and much smaller
		  $IL_PROG --quality 45 example.jpg avif

		  # Replace an existing example.webp
		  $IL_PROG -o example.png webp

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

if (( ${#IL_ARGS[@]} != 2 )); then
	usage >&2
	il_die "expected an input file and a format, got ${#IL_ARGS[@]} argument(s)"
fi

INPUT=${IL_ARGS[0]}
FORMAT=$(il_normalise_format "${IL_ARGS[1]}")

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

# What the input already is. Resolved before the target is acted on, because a
# file these tools cannot read should be reported as unreadable rather than as
# a failure of whatever was asked for.
INPUT_FORMAT=$(il_input_codec "$IL_EXT")

if [[ $INPUT_FORMAT == "$FORMAT" ]]; then
	il_die "$INPUT is already $FORMAT, and converting it to $FORMAT would only
    re-encode it. Ask for a different format, or use img-resize.sh to change
    its size."
fi

il_require_vips

# The canonical extension, not the requested name: jpeg is written as .jpg so
# that the file matches what everything else in the world calls it.
OUT_DIR=${IL_DIR:+$IL_DIR/}
OUT="${OUT_DIR}${IL_STEM}.${IL_OUT_EXT[$FORMAT]}"
il_refuse_if_exists "$OUT"

# Written somewhere nobody will look and moved into place at the end, so that a
# failed encode leaves no half-written file wearing the output's name.
if ! TMP=$(il_temp_path "${IL_DIR:-.}" "${IL_OUT_EXT[$FORMAT]}"); then
	il_fail "cannot create a temporary file in ${IL_DIR:-.}"
fi

if ! reason=$(vips copy "$INPUT" "$(il_save_name "$TMP" "$FORMAT")" 2>&1 >/dev/null); then
	rm -f -- "$TMP"
	il_fail "vips could not write $FORMAT: $(il_first_line "$reason")"
fi

# Exit 0 with a readable file is the normal outcome, but not the only one a
# broken build produces.
if ! il_verify_output "$TMP"; then
	rm -f -- "$TMP"
	il_fail "vips reported success but $OUT is not a readable image. This build
    cannot write $FORMAT; --doctor says which formats it can."
fi

il_install_output "$TMP" "$OUT"

printf 'converted %s -> %s\n' "$INPUT" "$OUT"
