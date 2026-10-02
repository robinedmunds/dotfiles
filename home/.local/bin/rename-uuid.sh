#!/usr/bin/env bash
#
# Rename files to random UUIDs, keeping their extensions.
#
# Files already named with a UUID are left alone, so running it twice is not
# destructive. Run it with --dry-run first.

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

usage() {
	cat <<-EOF
		Usage: $TOOL_PROG [OPTIONS] [DIRECTORY]

		Rename every file in DIRECTORY to a fresh lowercase UUID, keeping its
		extension. DIRECTORY defaults to the current directory.

		Files already named with a UUID are skipped, so the tool can be run
		repeatedly without renaming everything again.

		Symlinks are skipped: they are not files, and renaming one would leave
		its target under the old name.

	$(to_help_options)

	$(to_undo_log_note 'one "old<TAB>new" line per rename: the name the file had, then the name it has')

		Examples:
		  # See what would change, without changing it
		  $TOOL_PROG --dry-run

		  # Recurse, and record every rename so the run can be reversed
		  $TOOL_PROG --recursive --undo-log /tmp/renames.tsv

		  # Rename inside a directory
		  $TOOL_PROG ~/Downloads
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

# The directory may still arrive positionally, the way it always has. An
# explicit --directory wins, and passing both is a mistake worth reporting.
if (( ${#TOOL_ARGS[@]} > 1 )); then
	usage >&2
	to_die "expected at most one directory, got ${#TOOL_ARGS[@]}"
fi
if (( ${#TOOL_ARGS[@]} == 1 )) && [[ $TOOL_ROOT == "." ]]; then
	TOOL_ROOT=${TOOL_ARGS[0]}
fi

if [[ ! -d $TOOL_ROOT ]]; then
	to_die "not a directory: $TOOL_ROOT"
fi

# Matches a bare UUID stem, with or without a leading dot and in any case.
readonly UUID_STEM='^.*\.?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

rl_counters_reset
to_depth_args
to_prompt_ready

# -print0 with `read -d ''`, not `read`. The previous version piped `find` into
# a plain `read`, which split a filename containing a newline into two
# nonexistent paths and renamed neither.
while IFS= read -r -d '' file; do
	# find prints ./name when it is given "."; drop it so the name
	# being renamed and the name being renamed to look the same.
	file=${file#./}

	rl_split_name "$file"

	# ${RL_STEM,,} so an uppercase UUID counts as one too.
	if [[ ${RL_STEM,,} =~ $UUID_STEM ]]; then
		continue
	fi

	target="$(rl_join_ext "$(rl_uuid)" "$RL_EXT")"
	if [[ -n $RL_DIR ]]; then
		target="$RL_DIR/$target"
	fi

	rl_rename "$file" "$target"
done < <(find "$TOOL_ROOT" ${TOOL_DEPTH[@]+"${TOOL_DEPTH[@]}"} -type f -print0)

status=$TOOL_EX_OK
to_summary || status=$?
rl_log_reverse_hint
exit "$status"