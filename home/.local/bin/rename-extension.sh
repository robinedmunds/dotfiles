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

RL_PROG=$(basename -- "$0")

usage() {
	cat <<-EOF
		Usage: $RL_PROG [OPTIONS] <from-ext> <to-ext>

		Give every matching file a new extension, keeping the rest of its name.
		Matching is case-insensitive, so both .JPG and .jpg are found by "jpg".
		A leading dot on either argument is accepted and ignored.

	$(rl_help_options)

		Examples:
		  # See what would change, without changing it
		  $RL_PROG --dry-run jpg png

		  # Recurse, and record every rename so the run can be reversed
		  $RL_PROG --recursive --undo-log /tmp/renames.tsv jpg png

		  # Rename inside a directory rather than the current one
		  $RL_PROG --directory photos jpeg webp
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

# An extension is a suffix, never a path. Accept a leading dot, reject anything
# with a slash in it: "photos/*.jpg" would otherwise match nothing and still
# report success.
normalise_ext() {
	local ext=${1#.}

	if [[ -z $ext ]]; then
		rl_die "an extension cannot be empty"
	fi
	if [[ $ext == */* ]]; then
		rl_die "not an extension: $1"
	fi

	printf '%s' "$ext"
}

if (( ${#RL_ARGS[@]} != 2 )); then
	usage >&2
	rl_die "expected two extensions, got ${#RL_ARGS[@]}"
fi

FROM=$(normalise_ext "${RL_ARGS[0]}")
TO=$(normalise_ext "${RL_ARGS[1]}")

if [[ ! -d $RL_ROOT ]]; then
	rl_die "not a directory: $RL_ROOT"
fi

rl_counters_reset
rl_depth_args
rl_prompt_ready

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
done < <(find "$RL_ROOT" ${RL_DEPTH[@]+"${RL_DEPTH[@]}"} -type f -iname "*.$FROM" -print0)

status=$RL_EX_OK
rl_summary "*.$FROM" || status=$?
rl_log_reverse_hint
exit "$status"