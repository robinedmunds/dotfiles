#!/usr/bin/env bash
#
# Rename photos from their Exif capture time and camera model.
#
# The name is built here rather than handed to `exiv2 --rename`, so that
# --dry-run, the no-overwrite rule and the undo log all apply to it like they
# do to the other tools.
#
# Needs exiv2. Untested in an environment without it: the metadata reading is
# the one part of these tools that cannot be checked with nothing but bash.

set -euo pipefail

RL_LIB_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
if [[ ! -r $RL_LIB_DIR/rename-lib.sh ]]; then
	printf '%s: cannot find rename-lib.sh next to %s\n' \
		"$(basename -- "$0")" >&2
	exit 1
fi
# shellcheck source=rename-lib.sh
source "$RL_LIB_DIR/rename-lib.sh"

TOOL_PROG=$(basename -- "$0")

# exiv2 tags holding the moment the shutter fired, most specific first.
readonly DATE_TAGS=(
	Exif.Photo.DateTimeOriginal
	Exif.Image.DateTimeOriginal
	Exif.Photo.DateTimeDigitized
	Exif.Image.DateTime
)
readonly MODEL_TAG='Exif.Image.Model'

# Random characters appended to the name. Off by default: a random fallback made
# names unreproducible, so a second run over the same directory produced
# different names for the same files and any existing sort order came apart.
RANDOM_SUFFIX=0

usage() {
	cat <<-EOF
		Usage: $TOOL_PROG [OPTIONS]

		Rename each photo to the time it was taken and the camera that took it,
		as YYYYMMDD-HHMMSS-MODEL.jpg. Both .jpg and .jpeg are found, in any
		case.

		Reads Exif.Photo.DateTimeOriginal, falling back to the other standard
		date tags, then to the file's own modification time. The camera model is
		omitted when the file does not carry one. Two photos from the same
		second with the same camera get _1, _2 and so on appended.

	$(to_help_options)

	$(to_undo_log_note 'one "old<TAB>new" line per rename: the name the file had, then the name it has')

		Tool-specific options:
		  --random-suffix N   Append N random characters to each name. Off by
		                       default; see the note above.

		Examples:
		  # See what would change, without changing it
		  $TOOL_PROG --dry-run

		  # Rename one directory of photos, with a way back
		  $TOOL_PROG --directory ~/photos --undo-log /tmp/renames.tsv
	EOF
}

if to_wants_help "$@"; then
	if (( TOOL_WANTS_VERSION )); then
		printf '%s %s\n' "$TOOL_PROG" "$RL_VERSION"
	else
		usage
	fi
	exit 0
fi

# --random-suffix belongs to this tool alone, so lift it out before handing the
# rest to the shared parser.
rl_getopts_args=()
while (( $# )); do
	case $1 in
		--random-suffix)
			if (( $# < 2 )); then
				to_die "--random-suffix needs a number"
			fi
			RANDOM_SUFFIX=$2
			shift 2
			;;
		--random-suffix=*)
			RANDOM_SUFFIX=${1#--random-suffix=}
			shift
			;;
		--)
			shift
			rl_getopts_args+=("$@")
			break
			;;
		*)
			rl_getopts_args+=("$1")
			shift
			;;
	esac
done

to_getopts ${rl_getopts_args[@]+"${rl_getopts_args[@]}"}

if (( ${#TOOL_ARGS[@]} > 0 )); then
	usage >&2
	to_die "unexpected argument: ${TOOL_ARGS[0]} (this tool has no positional arguments)"
fi

case $RANDOM_SUFFIX in
	'' | *[!0-9]*)
		usage >&2
		to_die "--random-suffix needs a number"
		;;
esac

if [[ ! -d $TOOL_ROOT ]]; then
	to_die "not a directory: $TOOL_ROOT"
fi

to_require_cmd exiv2

# Reduce a tag value to something safe in a filename. Camera models arrive as
# "Canon EOS 5D Mark IV" and "NIKON D5300 ", which give names with spaces and a
# trailing dash if taken as they are.
sanitise() {
	local text=$1

	# Anything outside this set becomes a dash.
	text=${text//[^A-Za-z0-9._-]/-}
	# Collapse runs of dashes.
	while [[ $text == *--* ]]; do
		text=${text//--/-}
	done
	# Trim the ends.
	text=${text#-}
	text=${text%-}

	printf '%s' "$text"
}

# Print the value of the first tag that both exists and parses as a date, as
# YYYYMMDD-HHMMSS. exiv2 -Pv prints the value alone, so a value containing
# spaces needs no parsing.
capture_stamp() {
	local file=$1 tag value

	for tag in "${DATE_TAGS[@]}"; do
		if ! value=$(exiv2 -g "$tag" -Pv "$file" 2>/dev/null); then
			continue
		fi
		value=${value%%$'\n'*}
		# Trim surrounding whitespace, including any that came from the
		# tab-separated output of -Pv.
		value=${value#"${value%%[![:space:]]*}"}
		value=${value%"${value##*[![:space:]]}"}

		# Exif dates are "2024:01:02 11:22:33".
		if [[ $value =~ ^([0-9]{4}):([0-9]{2}):([0-9]{2})[[:space:]T]([0-9]{2}):([0-9]{2}):([0-9]{2}) ]]; then
			printf '%s%s%s-%s%s%s' \
				"${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" \
				"${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}" "${BASH_REMATCH[6]}"
			return 0
		fi
	done

	# No usable Exif date. The file's own modification time is deterministic,
	# which the random characters this replaced were not.
	local mtime
	if mtime=$(to_mtime_stamp "$file"); then
		printf '%s' "${mtime//[-_:]/}"
	fi
}

camera_model() {
	local file=$1 model=''

	if model=$(exiv2 -g "$MODEL_TAG" -Pv "$file" 2>/dev/null); then
		model=${model%%$'\n'*}
		model=${model#"${model%%[![:space:]]*}"}
		model=${model%"${model##*[![:space:]]}"}
		model=$(sanitise "$model")
	fi

	printf '%s' "$model"
}

random_suffix() {
	local n=$1

	if (( n == 0 )); then
		return 0
	fi

	printf '%s' "$(head -c 4096 /dev/urandom | tr -dc 'a-z0-9' | head -c "$n")"
}

rl_counters_reset
to_depth_args
to_prompt_ready

while IFS= read -r -d '' file; do
	# find prints ./name when it is given "."; drop it so the name
	# being renamed and the name being renamed to look the same.
	file=${file#./}

	rl_split_name "$file"

	stamp=$(capture_stamp "$file")
	if [[ -z $stamp ]]; then
		TOOL_FAILED=$(( TOOL_FAILED + 1 ))
		to_warn "no capture date and no readable mtime, skipping: $file"
		continue
	fi

	name="$stamp"
	model=$(camera_model "$file")
	if [[ -n $model ]]; then
		name="$name-$model"
	fi

	suffix=$(random_suffix "$RANDOM_SUFFIX")
	if [[ -n $suffix ]]; then
		name="$name-$suffix"
	fi

	target="$(rl_join_ext "$name" "$RL_EXT")"
	if [[ -n $RL_DIR ]]; then
		target="$RL_DIR/$target"
	fi

	# Burst frames share a second and a camera, so the name is taken rather
	# than assumed free.
	rl_free_path "$target"
	rl_rename "$file" "$RL_FREE_PATH"
done < <(find "$TOOL_ROOT" ${TOOL_DEPTH[@]+"${TOOL_DEPTH[@]}"} -type f \
	\( -iname '*.jpg' -o -iname '*.jpeg' \) -print0)

status=$TOOL_EX_OK
to_summary "*.jpg and *.jpeg" || status=$?
rl_log_reverse_hint
exit "$status"