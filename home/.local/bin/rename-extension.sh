#!/usr/bin/env bash
#
# Rename every file with one extension so it carries another.
#
# Run it with --dry-run first. It rewrites a whole directory's names in one
# pass, and it refuses to overwrite: if the destination name is already taken,
# that file is reported and left alone.

set -euo pipefail

RL_LIB_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
if [[ ! -r $RL_LIB_DIR/rename-lib.sh ]]; then
	printf '%s: cannot find rename-lib.sh next to %s\n' \
		"$(basename -- "$0")" "$0" >&2
	exit 1
fi
# shellcheck source=rename-lib.sh
source "$RL_LIB_DIR/rename-lib.sh"

TOOL_PROG=$(basename -- "$0")

usage() {
	cat <<-EOF
		Usage: $TOOL_PROG [OPTIONS] <from-ext> <to-ext>

		Give every matching file a new extension, keeping the rest of its name.
		Matching is case-insensitive, so both .JPG and .jpg are found by "jpg".
		A leading dot on either argument is accepted and ignored.

	$(to_help_options)

	$(to_undo_log_note 'one "old<TAB>new" line per rename: the name the file had, then the name it has')

		Examples:
		  # See what would change, without changing it
		  $TOOL_PROG --dry-run jpg png

		  # Recurse, and record every rename so the run can be reversed
		  $TOOL_PROG --recursive --undo-log /tmp/renames.tsv jpg png

		  # Rename inside a directory rather than the current one
		  $TOOL_PROG --directory photos jpeg webp
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

to_getopts "$@"

# An extension is a suffix, never a path. Accept a leading dot, reject anything
# with a slash in it: "photos/*.jpg" would otherwise match nothing and still
# report success.
normalise_ext() {
	local ext=${1#.}

	if [[ -z $ext ]]; then
		to_die "an extension cannot be empty"
	fi
	if [[ $ext == */* ]]; then
		to_die "not an extension: $1"
	fi

	printf '%s' "$ext"
}

if (( ${#TOOL_ARGS[@]} != 2 )); then
	usage >&2
	to_die "expected two extensions, got ${#TOOL_ARGS[@]}"
fi

FROM=$(normalise_ext "${TOOL_ARGS[0]}")
TO=$(normalise_ext "${TOOL_ARGS[1]}")

if [[ ! -d $TOOL_ROOT ]]; then
	to_die "not a directory: $TOOL_ROOT"
fi

rl_counters_reset
to_depth_args
to_prompt_ready

while IFS= read -r -d '' file; do
	# find prints ./name when it is given "."; drop it so the name
	# being renamed and the name being renamed to look the same.
	file=${file#./}

	rl_split_name "$file"

	# -iname already matched. Comparing the parsed extension as well keeps the
	# search and the name-splitting logic from disagreeing about what an
	# extension is.
	if [[ ${RL_EXT,,} != ${FROM,,} ]]; then
		continue
	fi

	dir=''
	if [[ -n $RL_DIR ]]; then
		dir="$RL_DIR/"
	fi

	# Build from the stem so the extension comes out as it was given:
	# SCAN.JPG becomes SCAN.png, not SCAN.PNG.
	rl_rename "$file" "$dir$(rl_join_ext "$RL_STEM" "$TO")"
done < <(find "$TOOL_ROOT" ${TOOL_DEPTH[@]+"${TOOL_DEPTH[@]}"} -type f -iname "*.$FROM" -print0)

status=$TOOL_EX_OK
to_summary "*.$FROM" || status=$?
rl_log_reverse_hint
exit "$status"