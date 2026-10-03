#!/usr/bin/env bash
#
# img-resize.sh and the three fixed-size wrappers that exec it.
#
# libvips is not installed on a machine running this suite and is not going to be
# installed for it. What these tools do is decide what to ask libvips for, and
# that decision is worth testing precisely because it does not need libvips to be
# there. So the three commands they shell out to are stood in for below, and each
# stand-in writes down that it was called: "a screenshot is resized without any
# reader being consulted" is an assertion about calls that did not happen, which
# is only checkable if the calls are recorded.
#
# Every case is about orientation, because that is where the tool has a decision
# to make rather than a command to run. The rest of it is libvips' work.

source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"

# ---------------------------------------------------------------------------
# Stand-ins for vips, vipsheader and exiftool
# ---------------------------------------------------------------------------

# A directory of stand-ins, at the front of PATH for the rest of the case. The
# three of them are named here rather than found, because a case that means to
# prove something is not consulted has to be able to guarantee the thing it is
# proving the absence of is findable in the first place.
STUB_DIR=''
OLD_PATH=''

stub_commands() {
	STUB_DIR="$SCRATCH/stubs"
	OLD_PATH=$PATH
	rm -rf -- "$STUB_DIR"
	mkdir -p "$STUB_DIR"
	PATH="$STUB_DIR:$PATH"
	export PATH
	export STUB_LOG="$SCRATCH/calls.log"
	export STUB_FACTS="$SCRATCH/default.facts"
	export STUB_EXIF_DATA=no
	: >"$STUB_LOG"

	# What a reader has not been told to answer with, it does not answer: a
	# missing key is a refusal, not an empty string.
	printf 'width 100\nheight 100\n' >"$STUB_FACTS"

	cat >"$STUB_DIR/vips" <<-'STUB'
		#!/usr/bin/env bash
		# Answers the three operations these tools use, and nothing else.
		set -uo pipefail
		op=${1:-}
		shift || true
		printf 'vips %s\n' "$*" >>"$STUB_LOG"

		case $op in
			--version)
				printf 'vips-8.15.1\n'
				;;
			-l)
				printf '  jpegsave    Save jpeg to file\n'
				printf '  pngsave     Save png to file\n'
				printf '  webpsave    Save webp to file\n'
				printf '  heifsave    Save heif to file\n'
				printf '  jpegload    Load jpeg from file\n'
				printf '  pngload     Load png from file\n'
				printf '  webpload    Load webp from file\n'
				printf '  heifload    Load heif from file\n'
				;;
			black)
				# The doctor probe: `vips black PATH 16 16 --bands 3`.
				printf 'black' >"${1:?}"
				;;
			thumbnail | copy | jpegsave | pngsave | webpsave | heifsave)
				# `vips thumbnail IN OUT W --height H --size force [--no-rotate]`,
				# or `vips pngsave IN OUT[compression=av1,Q=45]` for a write probe.
				# The save options libvips reads off the end of the name are not
				# part of the name it writes, so they come off here too.
				out=${2:?}
				out=${out%%[*}
				printf 'out' >"$out"
				;;
			*)
				printf 'vips: unsupported operation %s\n' "$op" >&2
				exit 1
				;;
		esac
	STUB

	cat >"$STUB_DIR/vipsheader" <<-'STUB'
		#!/usr/bin/env bash
		# Answers -f FIELD for the file named on the line, from a facts file
		# beside that file, or from $STUB_FACTS when it has none of its own.
		set -uo pipefail

		field=''
		file=''
		while (($#)); do
			case $1 in
				-f)
					field=${2:-}
					shift
					;;
				--) ;;
				-*) ;;
				*) file=$1 ;;
			esac
			shift
		done
		printf 'vipsheader -f %s %s\n' "$field" "$file" >>"$STUB_LOG"

		# The temporary file the tool writes has no facts of its own, which is
		# how it gets checked for being readable.
		facts="$file.facts"
		[[ -f $facts ]] || facts=$STUB_FACTS
		[[ -r $facts ]] || exit 1
		ext=${file##*.}

		# A fact may be qualified by extension, so that a build answering for
		# a jpeg and not for a png can be described at all. The qualification is
		# what the doctor's two probes differ on.
		#
		# No fact for a field means this reader does not answer that field at
		# all, which is how a build that cannot read an orientation is
		# described. There is deliberately no second way to say so: a key that
		# meant the same thing and read as though it did something would be
		# worse than the one honest spelling.
		fact() {
			local key=$1 value=''
			value=$(awk -v key="$key" '$1 == key { print $2; exit }' "$facts")
			if [[ -z $value ]]; then
				value=$(awk -v key="$key.$ext" '$1 == key { print $2; exit }' "$facts")
			fi
			printf '%s' "$value"
		}

		case $field in
			width | height)
				value=$(fact "$field")
				[[ -n $value ]] || exit 1
				printf '%s: %s\n' "$field" "$value"
				;;
			orientation)
				value=$(fact orientation)
				[[ -n $value ]] || exit 1
				printf 'orientation: %s (rotate 90 CW)\n' "$value"
				;;
			exif-data)
				# A build that carries the slot on every image it loads, which
				# is why asking it cannot tell an absent tag from a broken one.
				[[ ${STUB_EXIF_DATA:-no} == yes ]] || exit 1
				printf 'exif-data: "Exif\\0\\0"\n'
				;;
			*)
				exit 1
				;;
		esac
	STUB

	cat >"$STUB_DIR/exiftool" <<-'STUB'
		#!/usr/bin/env bash
		# `exiftool -n -s3 -Orientation FILE`. Exits 0 and prints nothing when
		# the file has no Orientation tag, which is what the real one does.
		set -uo pipefail
		printf 'exiftool %s\n' "$*" >>"$STUB_LOG"

		file=${!#}
		facts="$file.facts"
		[[ -f $facts ]] || facts=$STUB_FACTS
		value=''
		[[ -r $facts ]] || exit 0
		value=$(awk '$1 == "exiftool-orientation" { print $2; exit }' "$facts")
		[[ -n $value ]] || exit 0
		printf '%s\n' "$value"
	STUB

	chmod +x "$STUB_DIR/vips" "$STUB_DIR/vipsheader" "$STUB_DIR/exiftool"
}

# Put PATH back, whatever the case went on to assert. A case that leaked a
# directory of stand-ins into PATH would make every case after it test a fake.
unstub_commands() {
	PATH=$OLD_PATH
}

# True when the recorded calls contain LINE. grep -F, so a case states a call as
# it was written rather than as a regular expression.
called() {
	grep -Fq -- "$1" "$STUB_LOG"
}

# A fact about an input, for a reader to answer with.
in_facts() {
	local rel=$1 content=$2

	# Facts live beside the file they are about, and are named after it, so the
	# stand-in finds them without being told which file is which.
	in_home "$rel.facts" 644 "$content"
}

# ---------------------------------------------------------------------------
# A screenshot: no Exif at all
# ---------------------------------------------------------------------------

# 3840x2160, which is a real desktop screenshot and halves to 1920x1080.
in_screenshot() {
	in_home_bytes 'shot.png' 644 \
		'\211PNG\r\n\032\n\000\000\000\015IHDR\000\000\017\100\000\000\010\210IDATx\234c\374\017\000\031\375\003\335\377\221\211\351'
	in_facts 'shot.png' 'width 3840
height 2160'
}

case_a_screenshot_is_resized() {
	setup
	stub_commands
	in_screenshot

	run_tool img-resize-1080.sh shot.png

	assert_rc 0 'exit 0'
	assert_exists 'shot-1080.png' 'the resized screenshot is beside its input'
	assert_out 'resized shot.png 3840x2160' 'and it says what it did'
	unstub_commands
}
test_case 'a screenshot with no orientation tag is resized' case_a_screenshot_is_resized

# The point of deciding from the file's own bytes: no reader is asked, which is
# both the reason a screenshot works and two fewer processes for every file in a
# find -exec.
case_a_screenshot_consults_no_reader() {
	setup
	stub_commands
	in_screenshot

	run_tool img-resize-1080.sh shot.png

	assert_rc 0 'exit 0'
	if called 'vipsheader -f orientation'; then
		fail 'a reader was asked for the orientation of a file with no Exif'
		printf '          calls: %s\n' "$(one_line "$(cat -- "$STUB_LOG")")"
	else
		ok 'no reader was asked for the orientation'
	fi
	if called 'exiftool'; then
		fail 'exiftool was consulted about a file with no Exif'
	else
		ok 'nor was exiftool'
	fi
	# The orientation and the fact that no reader supplied it come back as one
	# string, because the read happens in a command substitution. A kind that
	# were lost to the subshell would leave --no-rotate off the command line
	# here, which is silent: the resize still succeeds and still comes out
	# upright, because there was no tag to apply in the first place.
	if called '--no-rotate'; then
		ok 'libvips is told not to rotate, so it cannot answer a second time'
	else
		fail 'the settled orientation did not survive the command substitution'
	fi
	unstub_commands
}
test_case 'a screenshot is resized without a reader being consulted' case_a_screenshot_consults_no_reader

# The bug this suite exists for. On a build where vipsheader carries the Exif
# slot on every image, asking it "-f exif-data" succeeds for a screenshot too, and
# "there is Exif here that nobody could read" is what a screenshot looks like from
# there. The tool must not depend on that field to tell the two apart.
case_a_screenshot_is_resized_when_the_exif_slot_answers() {
	setup
	stub_commands
	export STUB_EXIF_DATA=yes
	in_screenshot

	run_tool img-resize-1080.sh shot.png

	assert_rc 0 'exit 0'
	assert_exists 'shot-1080.png' 'the screenshot is resized'
	if called 'vipsheader -f exif-data'; then
		fail 'the Exif slot was asked about instead of the bytes of the file'
	else
		ok 'the Exif slot was never asked about'
	fi
	unstub_commands
}
test_case 'a screenshot is resized on a build where vipsheader exposes the Exif slot' \
	case_a_screenshot_is_resized_when_the_exif_slot_answers

case_a_jpeg_with_no_exif_is_resized() {
	setup
	stub_commands
	in_home_bytes 'plain.jpg' 644 '\377\330\377\340\000\020JFIF\000\001\001\000\000\001\000\001\000\000'
	in_facts 'plain.jpg' 'width 4000
height 3000'

	run_tool img-resize-1080.sh plain.jpg

	assert_rc 0 'exit 0'
	assert_exists 'plain-1080.jpg' 'a JPEG with no Exif is resized'
	unstub_commands
}
test_case 'a JPEG with no Exif in it is resized' case_a_jpeg_with_no_exif_is_resized

# A format that keeps its rotation outside Exif has nothing for the byte search
# to find, so "no Exif in the file" cannot mean "upright" for it. It has to go to
# a reader like anything else.
case_a_heic_with_no_exif_bytes_is_still_read() {
	setup
	stub_commands
	in_home_bytes 'clip.heic' 644 'ftypheic\000\000\000\010mdat'
	in_facts 'clip.heic' 'width 4000
height 3000'
	run_tool img-resize-1080.sh clip.heic

	assert_rc 1 'exit 1'
	if called 'vipsheader -f orientation'; then
		ok 'the orientation was read rather than assumed from absent Exif'
	else
		fail 'a heic was resized as though no Exif meant upright'
	fi
	unstub_commands
}
test_case 'a heic carries its rotation outside Exif, so it is never assumed upright' \
	case_a_heic_with_no_exif_bytes_is_still_read

# ---------------------------------------------------------------------------
# A photograph: Exif, and a reader that can read it
# ---------------------------------------------------------------------------

# A portrait photo stored sideways: 4000x3000 on disk, turned a quarter turn for
# display. Measured as 3000x4000, so the shortest side is 3000 and 1080 constrains
# the width: 1080x1440.
in_portrait_photo() {
	in_home_bytes 'holiday.jpg' 644 \
		'\377\330\377\341\000\030Exif\000\000MM\000*\000\000\000\010\000\000\000\011\001\003\000\000\000\001\000\011\000\002\021\000\003\021\000\000\000\022\000\016\021\001\000\002\000\000\000\000\000\000\377\331'
	in_facts 'holiday.jpg' 'width 4000
height 3000
orientation 6'
}

case_a_portrait_photo_is_measured_swapped() {
	setup
	stub_commands
	in_portrait_photo

	run_tool img-resize-1080.sh holiday.jpg

	assert_rc 0 'exit 0'
	assert_out 'has Exif orientation 6' 'the tag is reported'
	assert_out 'stored 4000x3000 is measured as 3000x4000' 'and so is the swap'
	assert_out 'holiday-1080.jpg 1080x1440' 'the shortest side is the one constrained'
	if called '--no-rotate'; then
		fail 'libvips was told not to rotate a tag the tool did read'
	else
		ok 'libvips applies the tag it was read'
	fi
	unstub_commands
}
test_case 'a portrait photo with orientation 6 is measured with its sides swapped' \
	case_a_portrait_photo_is_measured_swapped

case_exiftool_reads_what_vipsheader_cannot() {
	setup
	stub_commands
	in_home_bytes 'other.jpg' 644 '\377\330\377\341\000\030Exif\000\000MM\000*\000\000\000\010\000\000\000\011\001\003\000\000\000\001\000\011\000\002\021\000\003\021\000\000\000\022\000\016\021\001\000\002\000\000\000\000\000\000\377\331'
	in_facts 'other.jpg' 'width 4000
height 3000
exiftool-orientation 6'

	run_tool img-resize-1080.sh other.jpg

	assert_rc 0 'exit 0'
	assert_out 'other-1080.jpg 1080x1440' 'exiftool answered, so the swap was made'
	if called 'exiftool'; then
		ok 'exiftool was asked'
	else
		fail 'the fallback reader was never consulted'
	fi
	unstub_commands
}
test_case 'exiftool is the fallback when vipsheader cannot read the orientation' \
	case_exiftool_reads_what_vipsheader_cannot

# ---------------------------------------------------------------------------
# A file with Exif that nobody can read
# ---------------------------------------------------------------------------

in_unreadable_exif() {
	in_home_bytes 'broken.jpg' 644 \
		'\377\330\377\341\000\030Exif\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\377\331'
	in_facts 'broken.jpg' 'width 4000
height 3000'
}

case_exif_that_cannot_be_read_is_refused() {
	setup
	stub_commands
	in_unreadable_exif

	run_tool img-resize-1080.sh broken.jpg

	assert_rc 1 'exit 1'
	assert_err 'cannot read the orientation' 'it says the orientation is unreadable'
	assert_err 'sideways' 'and says what guessing would have cost'
	assert_err '--assume-upright' 'and names the way through'
	assert_absent 'broken-1080.jpg' 'nothing was written'
	unstub_commands
}
test_case 'a file carrying Exif that no reader can read is refused' \
	case_exif_that_cannot_be_read_is_refused

case_assume_upright_overrides_the_refusal() {
	setup
	stub_commands
	in_unreadable_exif

	run_tool img-resize-1080.sh --assume-upright broken.jpg

	assert_rc 0 'exit 0'
	assert_exists 'broken-1080.jpg' 'it is resized'
	if called '--no-rotate'; then
		ok 'libvips is told not to rotate, so it cannot rotate by a different answer'
	else
		fail 'libvips was left to apply a rotation the tool knows nothing about'
	fi
	unstub_commands
}
test_case '--assume-upright resizes a file whose orientation cannot be read' \
	case_assume_upright_overrides_the_refusal

# A reader that answers is a different problem from a reader that does not, and
# they are fixed in different places on the machine this ran on, so they are not
# reported as the same thing.
case_a_reader_answering_nonsense_is_refused() {
	setup
	stub_commands
	in_home_bytes 'odd.jpg' 644 '\377\330\377\341\000\030Exif\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\377\331'
	in_facts 'odd.jpg' 'width 4000
height 3000
orientation 0'

	run_tool img-resize-1080.sh odd.jpg

	assert_rc 1 'exit 1'
	assert_err 'is not an orientation from 1 to 8' 'it says what came back'
	assert_absent 'odd-1080.jpg' 'nothing was written'
	unstub_commands
}
test_case 'a reader answering something that is not an orientation is refused' \
	case_a_reader_answering_nonsense_is_refused

# ---------------------------------------------------------------------------
# Doctor
# ---------------------------------------------------------------------------

case_doctor_reports_both_formats() {
	setup
	stub_commands
	# A build that answers for a jpeg and not for a png: the difference is the
	# thing worth reporting, because a screenshot is a png.
	printf 'width 16\nheight 16\norientation.jpeg 1\n' >"$STUB_FACTS"

	run_tool img-resize-1080.sh --doctor

	assert_rc 0 'exit 0'
	assert_out 'jpeg  answers' 'the jpeg probe is reported'
	assert_out 'png   no:' 'and the png probe is reported apart from it'
	assert_out 'screenshot' 'it says why both are asked about'
	assert_out '--assume-upright' 'and names the way out of a refusal'
	unstub_commands
}
test_case '--doctor reports the orientation probe for a jpeg and a png apart' \
	case_doctor_reports_both_formats

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

# A wrapper is the tool people actually type. An option its --help does not
# mention is an option nobody finds, so the fixed-size help carries it too.
case_the_help_documents_assume_upright() {
	setup
	stub_commands

	run_tool img-resize-1080.sh --help

	assert_rc 0 'exit 0'
	assert_out '--assume-upright' 'the wrapper documents it'
	assert_not_out '--size' 'and offers no size of its own'

	run_tool img-resize.sh --help

	assert_rc 0 'exit 0'
	assert_out '--assume-upright' 'so does the tool that takes a size'
	assert_out '--size' 'which also documents --size'
	unstub_commands
}
test_case 'both forms of --help document --assume-upright' case_the_help_documents_assume_upright

run_cases