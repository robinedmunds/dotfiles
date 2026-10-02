#!/usr/bin/env bash
#
# Shared helpers for the rename-* tools.
#
# Sourced, never executed, which is why this file is 644 and not 755. Every
# tool that uses it resolves it relative to its own location, so the pair works
# identically from the Repository and from Home.
#
# This file is what is left of the old library once the parts that have nothing
# to do with renaming moved to tool-lib.sh: the option parser, the counters, the
# diagnostics, the summary line and the timestamp readers are shared with every
# other tool in the family, including sync-timestamps.sh, which renames nothing
# and cannot see them.
#
# What lives here, and why:
#
#   * One rename primitive. It refuses to overwrite, counts what it did, and
#     can write an undo log. Renaming a whole directory is not a moment to be
#     casual about.
#   * A free-name search, so two files renamed in the same millisecond do not
#     fight over one name.
#   * Name splitting that understands hidden files, so `.bashrc` is not read as
#     a file with a `.bashrc` extension.
#   * The undo log's own reverse command.
#
# Nothing here writes to stdout except the functions documented as printing.

# Sourcing twice must not re-run the declarations below.
if [[ -n ${RL_LIB_LOADED:-} ]]; then
	return 0
fi
RL_LIB_LOADED=1

# Bumped when the shared interface changes in a way that breaks a caller.
RL_VERSION='3'

# The floor this file is built on. Resolved from this file's own location rather
# than from $0, because a tool reaches this file through a path of its own and
# the two do not have to agree.
#
# Named apart from the tools' own RL_LIB_DIR, which points here, and unset
# afterwards so that neither name is left lying about what it holds.
rl_lib_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
if [[ ! -r $rl_lib_dir/tool-lib.sh ]]; then
	printf '%s: cannot find tool-lib.sh next to %s\n' \
		"${0##*/}" "$rl_lib_dir" >&2
	exit 1
fi
# shellcheck source=tool-lib.sh
source "$rl_lib_dir/tool-lib.sh"
unset rl_lib_dir

# Counters for the current run: the shared four, plus the names this family has
# claimed so far. That last one is renaming-specific and so is not in
# to_counters_reset, but it is reset at the same moment as the rest, which is why
# this wrapper exists rather than the tools doing both.
rl_counters_reset() {
	to_counters_reset

	# Names already claimed during this run. Without this, two files sharing a
	# millisecond both resolve to the same free name under --dry-run, because
	# a dry run creates nothing for the second one to collide with.
	#
	# Associative, because the names are filenames and not list positions, and
	# global with -g because a bare `declare` inside a function would make it
	# local to this one and leave the rest of the tool looking at nothing.
	declare -g -A RL_TAKEN=()
}

# ---------------------------------------------------------------------------
# Renaming
# ---------------------------------------------------------------------------

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
		TOOL_SKIPPED=$(( TOOL_SKIPPED + 1 ))
		to_warn "target exists, skipping: $src"
		return 0
	fi

	if (( TOOL_DRY_RUN )); then
		printf 'rename %s -> %s\n' "$src" "$dst"
		TOOL_PLANNED=$(( TOOL_PLANNED + 1 ))
		return 0
	fi

	if (( TOOL_INTERACTIVE )); then
		if [[ ! -e /dev/fd/3 ]]; then
			to_warn "interactive mode needs to_prompt_ready before the loop; skipping: $src"
			TOOL_SKIPPED=$(( TOOL_SKIPPED + 1 ))
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
				TOOL_SKIPPED=$(( TOOL_SKIPPED + 1 ))
				return 0
				;;
		esac
	fi

	if ! mv -n -- "$src" "$dst"; then
		TOOL_FAILED=$(( TOOL_FAILED + 1 ))
		to_warn "mv failed: $src -> $dst"
		return 0
	fi

	# `mv -n` exits 0 even when it declines to overwrite, so a success here
	# proves nothing. Check that the file actually moved. This is what stops
	# the tool announcing a rename it did not perform.
	if [[ -e $src || -L $src ]]; then
		TOOL_SKIPPED=$(( TOOL_SKIPPED + 1 ))
		to_warn "not renamed, skipping: $src"
		return 0
	fi

	TOOL_CHANGED=$(( TOOL_CHANGED + 1 ))
	printf 'renamed %s -> %s\n' "$src" "$dst"

	if [[ -n $TOOL_LOG ]]; then
		printf '%s\t%s\n' "$src" "$dst" >>"$TOOL_LOG" ||
			to_warn "could not append to undo log: $TOOL_LOG"
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

# ---------------------------------------------------------------------------
# Undo
# ---------------------------------------------------------------------------

# Print the undo log's own reverse command, so a log is usable without reading
# the tool's source.
#
# The records are replayed last-to-first. Sorting them would not do: a log that
# has had several runs appended to it has to be unwound in the order the renames
# happened, which is the order the lines are in.
rl_log_reverse_hint() {
	if [[ -z $TOOL_LOG ]]; then
		return 0
	fi

	printf '%s: reverse with:\n' "$TOOL_PROG"
	# The awk program keeps its own single quotes so the command is copy-pasteable,
	# and its $0 is escaped so this shell does not expand it first.
	printf '  awk %s %s | while IFS=%s read -r old new; do mv -- "$new" "$old"; done\n' \
		"'{a[NR]=\$0} END{for(i=NR;i>=1;i--)print a[i]}'" "$TOOL_LOG" "\$'\\t'"
}

# ---------------------------------------------------------------------------
# Random names
# ---------------------------------------------------------------------------

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
		to_die "cannot generate a UUID: install uuidgen, or provide /proc/sys/kernel/random/uuid"
	fi

	printf '%s' "$uuid" | tr '[:upper:]' '[:lower:]'
}
