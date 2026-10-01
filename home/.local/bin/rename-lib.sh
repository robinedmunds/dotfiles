#!/usr/bin/env bash
#
# Shared helpers for the rename-* tools.
#
# Sourced, never executed, which is why this file is 644 and not 755. Every
# tool that uses it resolves it relative to its own location, so the pair works
# identically from the Repository and from Home.
#
# What lives here, and why:
#
#   * One option parser and one help block, so the four tools cannot drift apart
#     in which flags they accept or how they describe them.
#   * One rename primitive. It refuses to overwrite, counts what it did, and
#     can write an undo log. Renaming a whole directory is not a moment to be
#     casual about.
#   * Name splitting that understands hidden files, so `.bashrc` is not read as
#     a file with a `.bashrc` extension.
#   * Timestamp formatting that works on BusyBox. `date -d "$(stat -c %y)"`
#     silently yields an empty string there, which used to turn `photo.jpg`
#     into `.jpg`.
#
# Nothing here writes to stdout except the functions documented as printing.

# Sourcing twice must not re-run the declarations below.
if [[ -n ${RL_LIB_LOADED:-} ]]; then
	return 0
fi
RL_LIB_LOADED=1

# Bumped when the shared interface changes in a way that breaks a caller.
RL_VERSION='2'

# Exit codes. Shared so a caller can branch on the outcome without knowing which
# tool it invoked.
RL_EX_OK=0
RL_EX_USAGE=1
RL_EX_FAILED=2

# Set by each tool: the name to prefix diagnostics with.
: "${RL_PROG:=rename}"

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------

rl_warn() {
	printf '%s: %s\n' "$RL_PROG" "$*" >&2
}

# Report a usage problem and stop. Usage problems are exit 1; a failure part way
# through a batch is exit 2. Keeping them apart means a caller can tell "you
# called me wrong" from "something went wrong".
rl_die() {
	rl_warn "$*"
	exit "$RL_EX_USAGE"
}

rl_require_cmd() {
	if ! command -v "$1" >/dev/null 2>&1; then
		rl_die "$1 is required, but is not installed"
	fi
}

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------

# Counters for the current run.
rl_counters_reset() {
	RL_RENAMED=0
	RL_PLANNED=0
	RL_SKIPPED=0
	RL_FAILED=0

	# find(1) depth arguments, so an unset one is never expanded under `set -u`.
	RL_DEPTH=(-maxdepth 1)

	# Names already claimed during this run. Without this, two files sharing a
	# millisecond both resolve to the same free name under --dry-run, because
	# a dry run creates nothing for the second one to collide with.
	#
	# Associative, because the names are filenames and not list positions, and
	# global with -g because a bare `declare` inside a function would make it
	# local to this one and leave the rest of the tool looking at nothing.
	declare -g -A RL_TAKEN=()
}

# True if the arguments ask for help or the version. Scans the whole list, so
# `tool --dry-run --help` prints help rather than complaining about --help.
rl_wants_help() {
	local arg

	RL_WANTS_VERSION=0
	for arg in "$@"; do
		case $arg in
			-h | --help)
				return 0
				;;
			-V | --version)
				RL_WANTS_VERSION=1
				return 0
				;;
		esac
	done

	return 1
}

# Parse the options every rename-* tool shares.
#
# The positional arguments left over come back in the global array RL_ARGS, not
# in "$@". A function cannot rewrite its caller's positional parameters:
# shifting inside here is forgotten the moment it returns, so the caller would
# go on to count its own options as arguments.
rl_getopts() {
	RL_DRY_RUN=0
	RL_INTERACTIVE=0
	RL_RECURSIVE=0
	RL_LOG=""
	RL_ROOT="."
	RL_ROOT_SET=0
	RL_ARGS=()

	while (( $# )); do
		case $1 in
			-n | --dry-run)
				RL_DRY_RUN=1
				;;
			-i | --interactive)
				RL_INTERACTIVE=1
				;;
			-r | --recursive)
				RL_RECURSIVE=1
				;;
			-C | --directory)
				if (( $# < 2 )); then
					rl_die "$1 needs a directory"
				fi
				RL_ROOT=$2
				RL_ROOT_SET=1
				shift
				;;
			--directory=*)
				RL_ROOT=${1#--directory=}
				RL_ROOT_SET=1
				;;
			--undo-log)
				if (( $# < 2 )); then
					rl_die "--undo-log needs a file to write to"
				fi
				RL_LOG=$2
				shift
				;;
			--undo-log=*)
				RL_LOG=${1#--undo-log=}
				;;
			--)
				shift
				RL_ARGS+=("$@")
				break
				;;
			-?*)
				rl_die "unknown option: $1 (try --help)"
				;;
			*)
				RL_ARGS+=("$1")
				;;
		esac
		# One step per iteration. Branches that consume a value of their own
		# shift once more before falling through to here.
		shift
	done

	if [[ -z $RL_LOG ]]; then
		return 0
	fi
	# Fail now rather than after renaming two thousand files.
	if ! : >>"$RL_LOG"; then
		rl_die "cannot write undo log: $RL_LOG"
	fi
}

# The options block, worded identically in every tool. Tools supply their own
# usage line, description and examples around it.
rl_help_options() {
	cat <<-'EOF'
		Options:
		  -n, --dry-run        Print every rename that would happen. Writes
		                       nothing, asks nothing.
		  -i, --interactive    Ask before each rename. Anything but y/yes
		                       leaves the file under its current name.
		  -r, --recursive      Descend into subdirectories.
		  -C, --directory DIR  Work inside DIR instead of the current directory.
		      --undo-log FILE  Append one "old<TAB>new" line per rename to
		                       FILE so the run can be reversed. Appends to an
		                       existing log; never truncates it. Keep it
		                       outside the directory being renamed: it is an
		                       ordinary file and gets renamed like any other.
		  -h, --help           Print this help and exit.
		  -V, --version        Print the version and exit.

		Exit codes:
		  0  Done. Files may have been skipped; the summary says how many.
		  1  Usage error, or nothing matched.
		  2  At least one rename failed.
	EOF
}

# Set the find(1) depth arguments: this directory only, or all of them.
rl_depth_args() {
	if (( RL_RECURSIVE )); then
		RL_DEPTH=()
	else
		RL_DEPTH=(-maxdepth 1)
	fi
}

# ---------------------------------------------------------------------------
# Renaming
# ---------------------------------------------------------------------------

# Print a one-line summary. Takes the thing that was searched, if there was
# one, so that a pattern which matched nothing is reported rather than passing
# for success. Returns the exit code the tool should use.
rl_summary() {
	local searched=${1-}
	local total=$(( RL_RENAMED + RL_PLANNED + RL_SKIPPED + RL_FAILED ))

	if (( RL_DRY_RUN )); then
		printf '%s: %d to rename, %d skipped, %d failed (dry run, nothing changed)\n' \
			"$RL_PROG" "$RL_PLANNED" "$RL_SKIPPED" "$RL_FAILED"
	else
		printf '%s: %d renamed, %d skipped, %d failed\n' \
			"$RL_PROG" "$RL_RENAMED" "$RL_SKIPPED" "$RL_FAILED"
	fi

	if (( total == 0 )) && [[ -n $searched ]]; then
		rl_warn "no files matched $searched"
		return "$RL_EX_USAGE"
	fi

	if (( RL_FAILED )); then
		return "$RL_EX_FAILED"
	fi

	return 0
}

# Print the undo log's own reverse command, so a log is usable without reading
# the tool's source.
#
# The records are replayed last-to-first. Sorting them would not do: a log that
# has had several runs appended to it has to be unwound in the order the renames
# happened, which is the order the lines are in.
rl_log_reverse_hint() {
	if [[ -z $RL_LOG ]]; then
		return 0
	fi

	printf '%s: reverse with:\n' "$RL_PROG"
	# The awk program keeps its own single quotes so the command is copy-pasteable,
	# and its $0 is escaped so this shell does not expand it first.
	printf '  awk %s %s | while IFS=%s read -r old new; do mv -- "$new" "$old"; done\n' \
		"'{a[NR]=\$0} END{for(i=NR;i>=1;i--)print a[i]}'" "$RL_LOG" "\$'\\t'"
}

# Preserve the stdin this tool was started with on fd 3, so that prompts can be
# read while a loop is walking a pipe. Call once, before the loop.
#
# Without it, `read` inside `while read -r -d '' … done < <(find …)` reads from
# the file list rather than from the person, and answers the next file's
# question with the next filename.
rl_prompt_ready() {
	exec 3<&0
}

# Move SRC to DST, honouring --dry-run, --interactive and --undo-log.
#
# It will not overwrite. A rename that destroys a file is worse than one that
# does nothing, and "the target already existed" is a decision the caller should
# get to make.
#
# Always returns 0: one unwritable file in a directory of two thousand should
# not abandon the other 1,999. Failures are counted and reported instead.
rl_rename() {
	local src=$1 dst=$2 reply

	if [[ -e $dst || -L $dst ]]; then
		RL_SKIPPED=$(( RL_SKIPPED + 1 ))
		rl_warn "target exists, skipping: $src"
		return 0
	fi

	if (( RL_DRY_RUN )); then
		printf 'rename %s -> %s\n' "$src" "$dst"
		RL_PLANNED=$(( RL_PLANNED + 1 ))
		return 0
	fi

	if (( RL_INTERACTIVE )); then
		if [[ ! -e /dev/fd/3 ]]; then
			rl_warn "interactive mode needs rl_prompt_ready before the loop; skipping: $src"
			RL_SKIPPED=$(( RL_SKIPPED + 1 ))
			return 0
		fi

		# fd 3, never stdin: stdin belongs to the file list right now.
		if ! read -r -p "rename '$src' -> '$dst'? [y/N] " reply <&3; then
			# End of input. Treat as "no" rather than aborting the batch.
			reply=""
			printf '\n'
		fi
		case ${reply,,} in
			y | yes) ;;
			*)
				RL_SKIPPED=$(( RL_SKIPPED + 1 ))
				return 0
				;;
		esac
	fi

	if ! mv -n -- "$src" "$dst"; then
		RL_FAILED=$(( RL_FAILED + 1 ))
		rl_warn "mv failed: $src -> $dst"
		return 0
	fi

	# `mv -n` exits 0 even when it declines to overwrite, so a success here
	# proves nothing. Check that the file actually moved. This is what stops
	# the tool announcing a rename it did not perform.
	if [[ -e $src || -L $src ]]; then
		RL_SKIPPED=$(( RL_SKIPPED + 1 ))
		rl_warn "not renamed, skipping: $src"
		return 0
	fi

	RL_RENAMED=$(( RL_RENAMED + 1 ))
	printf 'renamed %s -> %s\n' "$src" "$dst"

	if [[ -n $RL_LOG ]]; then
		printf '%s\t%s\n' "$src" "$dst" >>"$RL_LOG" ||
			rl_warn "could not append to undo log: $RL_LOG"
	fi

	return 0
}

# Set RL_FREE_PATH to DST, or to the first free DST_1, DST_2, ... that keeps its
# extension. Two files written in the same millisecond otherwise collide, and
# the loser is reported as a failure rather than renamed at all.
#
# This assigns rather than prints on purpose. The caller cannot use `$(rl_free_path
# …)`, because that runs in a subshell and the record of the name being claimed
# would be discarded when the subshell exits: the second file would then be
# handed the same name again, and --dry-run would disagree with the real run.
rl_free_path() {
	local dst=$1
	local dir stem ext n=1 candidate

	if ! rl_path_taken "$dst"; then
		RL_TAKEN["$dst"]=1
		RL_FREE_PATH=$dst
		return 0
	fi

	dir=$(dirname -- "$dst")
	if [[ $dir == "." ]]; then
		dir=""
	else
		dir="$dir/"
	fi

	rl_split_name "$dst"
	stem=$RL_STEM
	ext=$RL_EXT

	while :; do
		if [[ -n $ext ]]; then
			candidate="${dir}${stem}_${n}.${ext}"
		else
			candidate="${dir}${stem}_${n}"
		fi

		if ! rl_path_taken "$candidate"; then
			RL_TAKEN["$candidate"]=1
			RL_FREE_PATH=$candidate
			return 0
		fi

		n=$(( n + 1 ))
	done
}

# True if PATH is on disk, or has been claimed earlier in this run.
rl_path_taken() {
	if [[ -e $1 || -L $1 ]]; then
		return 0
	fi
	if [[ -n ${RL_TAKEN["$1"]:-} ]]; then
		return 0
	fi
	return 1
}

# ---------------------------------------------------------------------------
# Names
# ---------------------------------------------------------------------------

# Split PATH into RL_DIR, RL_BASE, RL_STEM and RL_EXT. RL_EXT carries no leading
# dot and is empty when the name has no extension.
#
# A leading dot marks a hidden file, not a separator, so the search for an
# extension starts after it: `.bashrc` has no extension, `.config.nvim` has the
# extension `nvim`. Testing `"$f" != *.*` instead, as the original scripts did,
# reads `.bashrc` as a file whose extension is `.bashrc`, and renames it into a
# timestamped non-hidden file that nothing sources any more.
rl_split_name() {
	local path=$1
	local base body hidden=''

	RL_DIR=$(dirname -- "$path")
	if [[ $RL_DIR == "." ]]; then
		RL_DIR=""
	fi

	base=$(basename -- "$path")
	RL_BASE=$base
	RL_EXT=""

	if [[ $base == .?* ]]; then
		hidden='.'
		body=${base#.}
	else
		body=$base
	fi

	# A trailing dot has nothing after it, so it is not an extension either.
	if [[ $body == *.* && $body != *. ]]; then
		RL_EXT=${body##*.}
		RL_STEM="${hidden}${body%.*}"
	else
		RL_STEM=$base
	fi
}

# Print STEM with EXT appended, or STEM alone when there is no extension.
rl_join_ext() {
	if [[ -n ${2:-} ]]; then
		printf '%s.%s' "$1" "$2"
	else
		printf '%s' "$1"
	fi
}

# Print FILE's modification time as YYYY-MM-DD_HHMMSS.mmm.
#
# The seconds come from `date -d @<epoch>`, which BusyBox and GNU coreutils
# both accept, and the milliseconds are lifted out of `stat -c %y` with pattern
# matching rather than handed to `date`. Both halves matter: BusyBox does not
# parse `stat`'s output as a date and does not implement %N, so the original
# `date -d "$(stat -c %y …)" +%Y-%m-%d_%H%M%S.%3N` produced an empty string
# there and the tools renamed files to bare extensions like `.jpg`.
rl_mtime_stamp() {
	local file=$1
	local epoch raw frac stamp

	if ! epoch=$(stat -c '%Y' -- "$file"); then
		return 1
	fi
	if ! stamp=$(date -d "@$epoch" +'%Y-%m-%d_%H%M%S' 2>/dev/null); then
		return 1
	fi
	if [[ -z $stamp ]]; then
		return 1
	fi

	frac='000'
	if raw=$(stat -c '%y' -- "$file"); then
		if [[ $raw =~ \.([0-9]+)[[:space:]] ]]; then
			frac=${BASH_REMATCH[1]}
		fi
	fi
	while (( ${#frac} < 3 )); do
		frac="${frac}0"
	done

	printf '%s.%s' "$stamp" "${frac:0:3}"
}

# Print a new random UUID in lowercase, from uuidgen if it is installed and from
# the kernel otherwise. uuidgen is absent from a lot of minimal installs,
# including BusyBox systems, where requiring it made the tool refuse to run at
# all.
rl_uuid() {
	local uuid=''

	if command -v uuidgen >/dev/null 2>&1; then
		uuid=$(uuidgen 2>/dev/null) || uuid=''
	fi

	if [[ -z $uuid && -r /proc/sys/kernel/random/uuid ]]; then
		uuid=$(< /proc/sys/kernel/random/uuid)
	fi

	if [[ -z $uuid ]]; then
		rl_die "cannot generate a UUID: install uuidgen, or provide /proc/sys/kernel/random/uuid"
	fi

	printf '%s' "$uuid" | tr '[:upper:]' '[:lower:]'
}