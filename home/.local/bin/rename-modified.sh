#!/usr/bin/env bash
#
# Rename files to the time they were last modified.
#
# Files are renamed where they are, not moved into the current directory. Two
# files modified in the same millisecond get _1, _2 and so on appended rather
# than one of them being reported as a failure.
#
# Supersedes rename-all-to-timestamp.sh, which took a directory and nothing
# else and is left in place only because it cannot be overwritten here.

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
		Usage: $TOOL_PROG [OPTIONS] <file-or-directory>...

		Rename each file to its modification time, as
		YYYY-MM-DD_HHMMSS.sss, keeping the original extension and directory.

		Directories are processed one level deep, or entirely with
		--recursive. Run it with --dry-run first: this renames everything it
		is pointed at.

	$(to_help_options)

	$(to_undo_log_note 'one "old<TAB>new" line per rename: the name the file had, then the name it has')

		Examples:
		  # Preview a single file
		  $TOOL_PROG --dry-run ~/Downloads/report.pdf

		  # A whole directory, with a record of every rename
		  $TOOL_PROG --undo-log /tmp/renames.tsv ~/Downloads

		  # Every file directly inside a directory
		  $TOOL_PROG ~/photos

		  # The same, walked all the way down
		  $TOOL_PROG --recursive --directory ~/photos
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

arg_count=${#TOOL_ARGS[@]}

if (( arg_count == 0 )); then
	# --directory on its own names the directory to sweep, which is the one
	# form of it that makes sense for a tool whose arguments are otherwise
	# paths.
	if (( TOOL_ROOT_SET )); then
		TOOL_ARGS=("$TOOL_ROOT")
	else
		usage >&2
		to_die "no files given"
	fi
elif (( TOOL_ROOT_SET )); then
	to_die "--directory names one directory; pass it on its own, or list the paths instead"
fi

for arg in "${TOOL_ARGS[@]}"; do
	if [[ ! -e $arg ]]; then
		to_die "no such file or directory: $arg"
	fi
done

# The tools used to run `date -d "$(stat -c %y f)"`. BusyBox cannot parse that
# as a date and does not implement %N, so the timestamp came back empty and
# `photo.jpg` was renamed to `.jpg` with exit status 0. If formatting still
# fails here, stop rather than write a bare extension.
stamp_of() {
	local file=$1 stamp

	if ! stamp=$(to_mtime_stamp "$file"); then
		to_die "cannot read the modification time of $file"
	fi
	if [[ -z $stamp ]]; then
		to_die "cannot read the modification time of $file"
	fi

	printf '%s' "$stamp"
}

rename_file() {
	local file=$1 stamp prefix target

	stamp=$(stamp_of "$file")

	# Split first, then take the directory from the result. Reading RL_DIR
	# before rl_split_name has filled it in leaves the prefix empty, and the
	# rename lands in the working directory instead of beside the file.
	rl_split_name "$file"

	# Build the target from the file's own directory. Deriving it from the
	# working directory instead moved files between directories whenever the
	# argument was a path, which is not what "rename" means.
	prefix=${RL_DIR:+$RL_DIR/}

	target="$(rl_join_ext "$prefix$stamp" "$RL_EXT")"

	# Take a free name. Two files touched in the same millisecond would
	# otherwise fight over one name, and the loser would be skipped rather than
	# renamed.
	rl_free_path "$target"
	rl_rename "$file" "$RL_FREE_PATH"
}

# Path arguments keep their own order; directory arguments expand. -print0 plus
# `read -d ''` rather than `read`, so a newline in a filename is part of the
# name instead of a second file.
targets=()
directories=()
for arg in "${TOOL_ARGS[@]}"; do
	if [[ -d $arg ]]; then
		directories+=("$arg")
	else
		targets+=("$arg")
	fi
done

rl_counters_reset
to_prompt_ready

for file in ${targets[@]+"${targets[@]}"}; do
	rename_file "$file"
done

for dir in ${directories[@]+"${directories[@]}"}; do
	if (( TOOL_RECURSIVE )); then
		depth=()
	else
		depth=(-maxdepth 1)
	fi

	while IFS= read -r -d '' file; do
		# find prints ./name when it is given "."; drop it so the undo
		# log reads consistently.
		file=${file#./}

		rename_file "$file"
	done < <(find "$dir" ${depth[@]+"${depth[@]}"} -type f -print0)
done

status=$TOOL_EX_OK
to_summary || status=$?
rl_log_reverse_hint
exit "$status"