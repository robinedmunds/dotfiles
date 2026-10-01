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

RL_PROG=$(basename -- "$0")

usage() {
	cat <<-EOF
		Usage: $RL_PROG [OPTIONS] [DIRECTORY]

		Rename every file in DIRECTORY to a fresh lowercase UUID, keeping its
		extension. DIRECTORY defaults to the current directory.

		Files already named with a UUID are skipped, so the tool can be run
		repeatedly without renaming everything again.

		Symlinks are skipped: they are not files, and renaming one would leave
		its target under the old name.

	$(rl_help_options)

		Examples:
		  # See what would change, without changing it
		  $RL_PROG --dry-run

		  # Recurse, and record every rename so the run can be reversed
		  $RL_PROG --recursive --undo-log /tmp/renames.tsv

		  # Rename inside a directory
		  $RL_PROG ~/Downloads
	EOF
}

if rl_wants_help "$@"; then
	if (( RL_WANTS_VERSION )); then
		printf '%s %s\n' "$RL_PROG" "$RL_VERSION"
	else
		usage
	fi
	exit 0
fi

rl_getopts "$@"

# The directory may still arrive positionally, the way it always has. An
# explicit --directory wins, and passing both is a mistake worth reporting.
if (( ${#RL_ARGS[@]} > 1 )); then
	usage >&2
	rl_die "expected at most one directory, got ${#RL_ARGS[@]}"
fi
if (( ${#RL_ARGS[@]} == 1 )) && [[ $RL_ROOT == "." ]]; then
	RL_ROOT=${RL_ARGS[0]}
fi

if [[ ! -d $RL_ROOT ]]; then
	rl_die "not a directory: $RL_ROOT"
fi

# Matches a bare UUID stem, with or without a leading dot and in any case.
readonly UUID_STEM='^.*\.?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

rl_counters_reset
rl_depth_args
rl_prompt_ready

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
done < <(find "$RL_ROOT" ${RL_DEPTH[@]+"${RL_DEPTH[@]}"} -type f -print0)

status=$RL_EX_OK
rl_summary || status=$?
rl_log_reverse_hint
exit "$status"