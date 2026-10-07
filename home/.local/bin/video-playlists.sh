#!/usr/bin/env bash
#
# Sort every video in a directory into playlists by length and by audio.
#
# ffprobe answers two questions per file -- does it have an audio stream, and
# how long is it -- and the answers are written to eight playlist files in the
# current directory: one per pairing of {audio, no-audio} with the duration
# buckets 0-10, 10-30, 30-60 and 60-plus seconds.
#
# ffprobe, not ffmpeg: opening a file and reading its header says whether an
# audio stream is present and what the duration is, and that is all a
# classification needs. Deciding whether a video is *audibly* silent would
# mean decoding all of it, which is a different and much slower tool.
#
# The playlists hold one absolute path per line, sorted, and are rewritten
# from empty on every run, so nothing from an earlier run can survive in them
# -- a file that moved to another bucket or left the directory is gone by the
# time the run finishes. A bucket with no videos in it is an empty file
# rather than a missing one, so all eight names are always there to be handed
# to a player. The names end in .txt, so pointing the tool at the directory
# its own playlists live in does not read them back.

set -euo pipefail

VP_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
if [[ ! -r $VP_DIR/tool-lib.sh ]]; then
	printf '%s: cannot find tool-lib.sh next to %s\n' \
		"$(basename -- "$0")" "$0" >&2
	exit 1
fi
# shellcheck source=tool-lib.sh
source "$VP_DIR/tool-lib.sh"

TOOL_PROG=$(basename -- "$0")

# What counts as a video: the formats gallery.sh shuffles, minus the image
# ones, because this tool would have nothing to ask an image. Compared
# against the lowered name in the collecting loop rather than by find's
# -iregex, whose regex flavour depends on -regextype, a GNU extension: every
# tool in this family is expected to run on BusyBox as well.

usage() {
	cat <<-EOF
		Usage: $TOOL_PROG [OPTIONS]

		Probe every video file in a directory with ffprobe and sort it
		into eight playlist files written to the current directory:

		  audio-0-10-seconds.txt       no-audio-0-10-seconds.txt
		  audio-10-30-seconds.txt      no-audio-10-30-seconds.txt
		  audio-30-60-seconds.txt      no-audio-30-60-seconds.txt
		  audio-60-plus-seconds.txt    no-audio-60-plus-seconds.txt

		An audio classification means ffprobe found an audio stream in
		the file; whether that stream carries anything audible is not
		tested. A video whose sound is silent all the way through is
		listed under audio.

		The buckets take their lower bound and leave out the upper one,
		so a video of exactly 10 seconds is listed in 10-30, and one of
		exactly 60 seconds in 60-plus.

		Each playlist holds one absolute path per line, sorted, and is
		rewritten from empty on every run: a file that changed bucket or
		leave the directory cannot linger in a playlist from an earlier
		run. A bucket with no videos in it is an empty file, not a
		missing one. The names end in .txt, so a second run over the
		directory these playlists are in finds no video of its own work.

		--dry-run prints "FILE -> PLAYLIST" for every video it would
		list and writes none of the eight files.

		--interactive and --undo-log are not for this tool: it changes
		no video file, only writes playlists of its own.

	$(to_help_options)

		Examples:
		  # Sort the current directory's videos
		    $TOOL_PROG

		  # Sort a folder of downloads; playlists still land here
		    $TOOL_PROG --directory ~/videos

		  # See the classification without writing anything
		    $TOOL_PROG --dry-run --directory ~/videos

		  # Every video in the whole tree below a directory
		    $TOOL_PROG --recursive --directory ~/videos
	EOF
}

if to_wants_help "$@"; then
	if (( TOOL_WANTS_VERSION )); then
		printf '%s %s\n' "$TOOL_PROG" "$TOOL_VERSION"
	else
		usage
	fi
	exit 0
fi

to_getopts "$@"

# These two are refused rather than accepted and ignored: --undo-log in
# particular would be validated, record nothing, and read like it had worked.
if (( TOOL_INTERACTIVE )) || [[ -n $TOOL_LOG ]]; then
	to_die "--interactive and --undo-log are not for this tool: it reads video headers and writes playlists of its own"
fi

if (( ${#TOOL_ARGS[@]} )); then
	usage >&2
	to_die "expected no arguments, got ${#TOOL_ARGS[@]}; the directory to read is -C DIR"
fi

if [[ ! -d $TOOL_ROOT ]]; then
	to_die "not a directory: $TOOL_ROOT"
fi

# Resolved once, so the playlists carry absolute paths whether the directory
# was given as ., a relative path or a symlinked one.
root=$(CDPATH='' cd -- "$TOOL_ROOT" && pwd -P)

to_require_cmd ffprobe
to_counters_reset
to_depth_args

# The eight playlist names, built rather than listed so the two halves of
# every name cannot be edited apart.
VP_PLAYLISTS=()
for class in audio no-audio; do
	for span in 0-10 10-30 30-60 60-plus; do
		VP_PLAYLISTS+=("$class-$span-seconds.txt")
	done
done

# Collect the videos first, before anything is written: a directory with no
# video in it is a usage problem, and a run that ends that way should leave
# no empty playlists behind to be mistaken for an answer.
VP_FILES=()
while IFS= read -r -d '' file; do
	# The name, lowered, so MP4 and mkv are matched by the same case
	# pattern without asking find for a regex flavour it may not have.
	name=${file##*/}
	case ${name,,} in
		*.3gp | *.avi | *.divx | *.flv | *.m2ts | *.m4v | *.mkv | *.mov | \
			*.mpg | *.mpeg | *.mp4 | *.mts | *.ogv | *.ts | *.webm | *.wmv)
			VP_FILES+=("$file")
			;;
	esac
done < <(find "$root" ${TOOL_DEPTH[@]+"${TOOL_DEPTH[@]}"} -type f -print0)

if (( ${#VP_FILES[@]} == 0 )); then
	to_warn "no video files in $root"
	exit "$TOOL_EX_USAGE"
fi

if (( ! TOOL_DRY_RUN )); then
	for name in "${VP_PLAYLISTS[@]}"; do
		# Truncated here, not appended to: a playlist from a run that
		# ended early must not be read as this run's output. The check
		# is explicit so an unwritable directory is a usage error with
		# a name attached, rather than a bare "Permission denied".
		if ! : >"$name"; then
			to_die "cannot write playlist: $PWD/$name"
		fi
	done
fi

# Print FILE's duration in seconds on stdout, or fail. Three readings are
# tried, because containers disagree about where the length lives: the
# format header, then the longest stream when the header has nothing.
# Only a plain number is accepted -- ffprobe answers N/A for a header it
# cannot fill in, and N/A compared as a duration would be nonsense.
vp_duration() {
	local file=$1 raw best line n

	raw=''
	raw=$(ffprobe -v error -show_entries format=duration \
		-of default=noprint_wrappers=1:nokey=1 -- "$file" 2>/dev/null) || raw=''
	if [[ $raw =~ ^[0-9]+([.][0-9]+)?$ ]]; then
		printf '%s' "$raw"
		return 0
	fi

	raw=''
	raw=$(ffprobe -v error -select_streams v -show_entries stream=duration \
		-of default=noprint_wrappers=1:nokey=1 -- "$file" 2>/dev/null) || raw=''

	# Whole seconds are all a bucket edge can see: the buckets meet at
	# 10, 30 and 60, so two stream lengths that share a whole second
	# always land in the same bucket whichever of them is taken, and
	# bash can compare the integers without a float anywhere.
	best=''
	while IFS= read -r line; do
		if [[ $line =~ ^[0-9]+ ]]; then
			n=${BASH_REMATCH[0]}
			if [[ -z $best ]] || (( n > best )); then
				best=$n
			fi
		fi
	done <<<"$raw"

	if [[ -z $best ]]; then
		return 1
	fi
	printf '%s' "$best"
}

for file in "${VP_FILES[@]}"; do
	# One probe asks only about audio streams: empty output means the
	# file has none, a non-zero exit means the file could not be read
	# at all. The two are told apart by the exit status, which is why
	# stderr is dropped here rather than read.
	streams=''
	if ! streams=$(ffprobe -v error -select_streams a -show_entries stream=index \
		-of csv=p=0 -- "$file" 2>/dev/null); then
		TOOL_FAILED=$(( TOOL_FAILED + 1 ))
		to_warn "cannot probe: $file"
		continue
	fi

	class=no-audio
	if [[ -n $streams ]]; then
		class=audio
	fi

	if ! duration=$(vp_duration "$file"); then
		TOOL_FAILED=$(( TOOL_FAILED + 1 ))
		to_warn "cannot read duration: $file"
		continue
	fi

	# Floor of the seconds, which is exactly the bucket: the edges are
	# whole numbers and each bucket holds its lower bound.
	whole=${duration%%.*}
	if (( whole < 10 )); then
		span=0-10
	elif (( whole < 30 )); then
		span=10-30
	elif (( whole < 60 )); then
		span=30-60
	else
		span=60-plus
	fi

	name="$class-$span-seconds.txt"

	if (( TOOL_DRY_RUN )); then
		printf '%s -> %s\n' "$file" "$name"
		TOOL_PLANNED=$(( TOOL_PLANNED + 1 ))
		continue
	fi

	if ! printf '%s\n' "$file" >>"$name"; then
		to_die "cannot write playlist: $PWD/$name"
	fi
	TOOL_CHANGED=$(( TOOL_CHANGED + 1 ))
done

if (( ! TOOL_DRY_RUN )); then
	# Sorted after the walk rather than during it: appending in find
	# order is the cheap part, and one sort per playlist at the end
	# gives every file the same order on every run regardless of how
	# the directory happened to be enumerated.
	for name in "${VP_PLAYLISTS[@]}"; do
		LC_ALL=C sort -o "$name" "$name"
	done
fi

status=$TOOL_EX_OK
to_summary '' 'listed' 'to list' || status=$?
exit "$status"
