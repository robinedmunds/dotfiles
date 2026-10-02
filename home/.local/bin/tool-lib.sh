#!/usr/bin/env bash
#
# Shared helpers for the scripts in ~/.local/bin.
#
# Sourced, never executed, which is why this file is 644 and not 755. Every tool
# that uses it resolves it relative to its own location, so the family works
# identically from the Repository and from Home.
#
# This file is the floor the tool families are built on: the option parser, the
# counters, the diagnostics and the two timestamp readers live here, so
# sync-timestamps.sh and the rename-* tools cannot drift apart in which flags
# they accept or how they describe them. What is specific to renaming --
# rl_rename, the name splitting, the free-name search -- stays in
# rename-lib.sh, which sources this file.
#
# What lives here, and why:
#
#   * One option parser and one help block, so the tools cannot drift apart in
#     which flags they accept or how they describe them.
#   * Counters and a summary line. A tool that works through a directory of two
#     thousand files says what it did to all of them, including the ones it
#     declined to touch.
#   * Prompt plumbing on fd 3, so a tool walking a pipe can still ask a person
#     questions.
#   * Timestamp reading that works on BusyBox, to whole seconds and to a
#     readable stamp.
#
# Nothing here writes to stdout except the functions documented as printing.

# Sourcing twice must not re-run the declarations below.
if [[ -n ${TOOL_LIB_LOADED:-} ]]; then
	return 0
fi
TOOL_LIB_LOADED=1

# Bumped when the shared interface changes in a way that breaks a caller.
TOOL_VERSION='1'

# Exit codes. Shared so a caller can branch on the outcome without knowing which
# tool it invoked.
#
# These are the numbers rename-lib.sh has always used, and they are the ones the
# img-* tools disagree with: image-lib.sh takes 1 for a failure and 2 for a
# usage error, the other way round. Every tool here is a member of the rename
# family, so the rename family's numbering is the one kept. Reconciling the img
# tools is a separate piece of work, because docs/specs/image-tools.md pins their
# behaviour.
TOOL_EX_OK=0
TOOL_EX_USAGE=1
TOOL_EX_FAILED=2

# Set by each tool: the name to prefix diagnostics with.
: "${TOOL_PROG:=tool}"

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------

to_warn() {
	printf '%s: %s\n' "$TOOL_PROG" "$*" >&2
}

# Report a usage problem and stop. Usage problems are exit 1; a failure part way
# through a batch is exit 2. Keeping them apart means a caller can tell "you
# called me wrong" from "something went wrong".
to_die() {
	to_warn "$*"
	exit "$TOOL_EX_USAGE"
}

to_require_cmd() {
	if ! command -v "$1" >/dev/null 2>&1; then
		to_die "$1 is required, but is not installed"
	fi
}

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------

# Counters for the current run.
#
# TOOL_CHANGED rather than TOOL_RENAMED: a tool that only changes timestamps
# renames nothing, and a counter named after the loudest member of the family
# would be a lie in every other one.
to_counters_reset() {
	TOOL_CHANGED=0
	TOOL_PLANNED=0
	TOOL_SKIPPED=0
	TOOL_FAILED=0

	# find(1) depth arguments, so an unset one is never expanded under `set -u`.
	TOOL_DEPTH=(-maxdepth 1)
}

# True if the arguments ask for help or the version. Scans the whole list, so
# `tool --dry-run --help` prints help rather than complaining about --help.
to_wants_help() {
	local arg

	TOOL_WANTS_VERSION=0
	for arg in "$@"; do
		case $arg in
			-h | --help)
				return 0
				;;
			-V | --version)
				TOOL_WANTS_VERSION=1
				return 0
				;;
		esac
	done

	return 1
}

# Parse the options every tool in this family shares.
#
# The positional arguments left over come back in the global array TOOL_ARGS, not
# in "$@". A function cannot rewrite its caller's positional parameters:
# shifting inside here is forgotten the moment it returns, so the caller would go
# on to count its own options as arguments.
to_getopts() {
	TOOL_DRY_RUN=0
	TOOL_INTERACTIVE=0
	TOOL_RECURSIVE=0
	TOOL_LOG=""
	TOOL_ROOT="."
	TOOL_ROOT_SET=0
	TOOL_ARGS=()

	while (( $# )); do
		case $1 in
			-n | --dry-run)
				TOOL_DRY_RUN=1
				;;
			-i | --interactive)
				TOOL_INTERACTIVE=1
				;;
			-r | --recursive)
				TOOL_RECURSIVE=1
				;;
			-C | --directory)
				if (( $# < 2 )); then
					to_die "$1 needs a directory"
				fi
				TOOL_ROOT=$2
				TOOL_ROOT_SET=1
				shift
				;;
			--directory=*)
				TOOL_ROOT=${1#--directory=}
				TOOL_ROOT_SET=1
				;;
			--undo-log)
				if (( $# < 2 )); then
					to_die "--undo-log needs a file to write to"
				fi
				TOOL_LOG=$2
				shift
				;;
			--undo-log=*)
				TOOL_LOG=${1#--undo-log=}
				;;
			--)
				shift
				TOOL_ARGS+=("$@")
				break
				;;
			-?*)
				to_die "unknown option: $1 (try --help)"
				;;
			*)
				TOOL_ARGS+=("$1")
				;;
		esac
		# One step per iteration. Branches that consume a value of their own
		# shift once more before falling through to here.
		shift
	done

	if [[ -z $TOOL_LOG ]]; then
		return 0
	fi
	# Fail now rather than after changing two thousand files.
	if ! : >>"$TOOL_LOG"; then
		to_die "cannot write undo log: $TOOL_LOG"
	fi
}

# The options block, worded identically in every tool. Tools supply their own
# usage line, description and examples around it.
#
# --undo-log is described without naming a record format, because the format is
# each tool's own and a shared block that described the rename one would be
# telling a lie to every other tool. Each tool states its format with
# to_undo_log_note, which keeps the wording of that one sentence shared.
to_help_options() {
	cat <<-'EOF'
		Options:
		  -n, --dry-run        Print every change that would happen. Writes
		                       nothing, asks nothing.
		  -i, --interactive    Ask before each change. Anything but y/yes
		                       leaves the file as it is.
		  -r, --recursive      Descend into subdirectories.
		  -C, --directory DIR  Work inside DIR instead of the current directory.
		      --undo-log FILE  Append a line per change to FILE so the run can
		                       be reversed; this tool's help gives the format.
		                       Appends to an existing log; never truncates it.
		                       Keep it outside every directory the tool is
		                       pointed at: it is an ordinary file, and a tool
		                       working through a directory will find it there.
		  -h, --help           Print this help and exit.
		  -V, --version        Print the version and exit.

		Exit codes:
		  0  Done. Files may have been skipped; the summary says how many.
		  1  Usage error, or nothing matched.
		  2  At least one change failed.
	EOF
}

# One sentence for a tool's usage block, naming the format its undo log
# records. Shared so that the tools cannot word the same fact four different
# ways; the format itself is passed in, because it is each tool's own.
#
# Flush left, with no leading whitespace. A usage block is a `cat <<-` heredoc,
# and the tab stripping that makes those readable happens before command
# substitution, so any indentation this printed would survive as the only
# indented line in the block.
to_undo_log_note() {
	printf 'The undo log records %s.\n' "$1"
}

# Set the find(1) depth arguments: this directory only, or all of them.
to_depth_args() {
	if (( TOOL_RECURSIVE )); then
		TOOL_DEPTH=()
	else
		TOOL_DEPTH=(-maxdepth 1)
	fi
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

# Print a one-line summary. Takes the thing that was searched, if there was
# one, so that a pattern which matched nothing is reported rather than passing
# for success. Returns the exit code the tool should use.
#
# The two verbs default to the renaming family's wording, because that is what
# most of these tools do; a tool that does something else passes its own. The
# defaults are what keeps rename-*.sh's output unchanged by this being shared.
to_summary() {
	local searched=${1-}
	local done_verb=${2-renamed} todo_verb=${3-to rename}
	local total=$(( TOOL_CHANGED + TOOL_PLANNED + TOOL_SKIPPED + TOOL_FAILED ))

	if (( TOOL_DRY_RUN )); then
		printf '%s: %d %s, %d skipped, %d failed (dry run, nothing changed)\n' \
			"$TOOL_PROG" "$TOOL_PLANNED" "$todo_verb" "$TOOL_SKIPPED" "$TOOL_FAILED"
	else
		printf '%s: %d %s, %d skipped, %d failed\n' \
			"$TOOL_PROG" "$TOOL_CHANGED" "$done_verb" "$TOOL_SKIPPED" "$TOOL_FAILED"
	fi

	if (( total == 0 )) && [[ -n $searched ]]; then
		to_warn "no files matched $searched"
		return "$TOOL_EX_USAGE"
	fi

	if (( TOOL_FAILED )); then
		return "$TOOL_EX_FAILED"
	fi

	return 0
}

# ---------------------------------------------------------------------------
# Prompting
# ---------------------------------------------------------------------------

# Preserve the stdin this tool was started with on fd 3, so that prompts can be
# read while a loop is walking a pipe. Call once, before the loop.
#
# Without it, `read` inside `while read -r -d '' … done < <(find …)` reads from
# the file list rather than from the person, and answers the next file's
# question with the next filename.
to_prompt_ready() {
	exec 3<&0
}

# ---------------------------------------------------------------------------
# Timestamps
# ---------------------------------------------------------------------------

# Print FILE's modification time in seconds since the epoch.
#
# `stat -c %Y` rather than anything derived from a formatted date: the seconds
# are what a comparison between two files has to be made on, and they are the
# only timestamp that survives a round trip through `touch -d @…` on a machine
# whose stat cannot report fractions.
to_mtime_epoch() {
	local file=$1 epoch

	if ! epoch=$(stat -c '%Y' -- "$file"); then
		return 1
	fi
	if [[ -z $epoch ]]; then
		return 1
	fi

	printf '%s' "$epoch"
}

# Print FILE's modification time as YYYY-MM-DD_HHMMSS.mmm.
#
# The seconds come from `date -d @<epoch>`, which BusyBox and GNU coreutils
# both accept, and the milliseconds are lifted out of `stat -c %y` with pattern
# matching rather than handed to `date`. Both halves matter: BusyBox does not
# parse `stat`'s output as a date and does not implement %N, so the original
# `date -d "$(stat -c %y …)" +%Y-%m-%d_%H%M%S.%3N` produced an empty string
# there and the tools renamed files to bare extensions like `.jpg`.
#
# For reading a timestamp, not for setting one: the fraction is only ever
# reported here, never handed back to touch.
to_mtime_stamp() {
	local file=$1
	local epoch raw frac stamp

	if ! epoch=$(to_mtime_epoch "$file"); then
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
