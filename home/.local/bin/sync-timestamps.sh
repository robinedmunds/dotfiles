#!/usr/bin/env bash
#
# Replicate one directory's file timestamps onto the matching files in another.
#
# DIR_A is authoritative. DIR_B is never read for its own timestamps: it is
# brought into line with DIR_A, and a file in DIR_B that DIR_A does not have is
# left alone and reported.
#
# Supersedes the pair-of-files version, which took two files and gave both of
# them the earlier of the two timestamps. That could not describe a pair of
# directories, and "the earlier one wins" is a policy this tool does not have.

set -euo pipefail

TL_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
if [[ ! -r $TL_DIR/tool-lib.sh ]]; then
	printf '%s: cannot find tool-lib.sh next to %s\n' \
		"$(basename -- "$0")" "$0" >&2
	exit 1
fi
# shellcheck source=tool-lib.sh
source "$TL_DIR/tool-lib.sh"

TOOL_PROG=$(basename -- "$0")

usage() {
	cat <<-EOF
		Usage: $TOOL_PROG [OPTIONS] <dir-a> <dir-b>

		Give each file in DIR_B the modification time of the file at the same
		relative path in DIR_A. DIR_A is the source of truth: DIR_B's own
		timestamps are never the answer, only the thing being corrected.

		Files are paired by relative path, so a file renamed on one side has no
		counterpart on the other and is reported rather than paired with the
		wrong one.

		Both directories are searched one level deep, or entirely with
		--recursive. Subdirectory timestamps, symlinks and file contents are not
		touched. A file in DIR_B that DIR_A does not have is left alone and
		reported: DIR_B is allowed to hold more than DIR_A does, but that is
		worth knowing.

		Run it with --dry-run first. Unlike a rename, nothing here can be moved
		back afterwards: --undo-log records where to return to, which is not the
		same thing.

		Setting a timestamp with 'touch -r' sets the access time as well as the
		modification time, so a file in DIR_B is left with both of the times
		DIR_A has for it.

	$(to_help_options)

	$(to_undo_log_note 'one "path<TAB>old_epoch" line per file it changed, whole seconds since the epoch')

		Examples:
		  # See what would change, without changing it
		  $TOOL_PROG --dry-run ~/photos/original ~/photos/copy

		  # The whole tree, with a way back to the old timestamps
		  $TOOL_PROG --recursive --undo-log /tmp/times.tsv ~/backup/a ~/backup/b

		  # Change nothing until each one is agreed to
		  $TOOL_PROG --interactive ~/backup/a ~/backup/b
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

# -C names the directory to work in, and this tool's two arguments already are
# directories. Accepting the flag and then working somewhere else would be the
# worst of both, so it is refused rather than ignored.
if (( TOOL_ROOT_SET )); then
	usage >&2
	to_die "--directory is not for this tool: name both directories as arguments"
fi

if (( ${#TOOL_ARGS[@]} != 2 )); then
	usage >&2
	to_die "expected two directories, got ${#TOOL_ARGS[@]}"
fi

ARG_A=${TOOL_ARGS[0]}
ARG_B=${TOOL_ARGS[1]}

for arg in "$ARG_A" "$ARG_B"; do
	if [[ ! -d $arg ]]; then
		to_die "not a directory: $arg"
	fi
done

# Normalise both to a physical path, so that a symlink, a ".." and a trailing
# slash cannot make two arguments look like the same directory, or like one
# inside the other. Everything below relies on the result: the relative paths
# come from stripping "$A/" off what find prints, which needs an absolute path
# with no trailing slash and no second slash.
if ! A=$(CDPATH='' cd -- "$ARG_A" && pwd -P); then
	to_die "cannot enter directory: $ARG_A"
fi
if ! B=$(CDPATH='' cd -- "$ARG_B" && pwd -P); then
	to_die "cannot enter directory: $ARG_B"
fi

if [[ $A == "$B" ]]; then
	to_die "the two directories are the same: $A"
fi

# True when INNER is OUTER or somewhere under it.
inside() {
	local outer=$1 inner=$2 prefix

	# "/" with a slash appended is "//", which matches no path at all. Built
	# here rather than interpolated so that a root argument is caught like any
	# other.
	case $outer in
		/) prefix=/ ;;
		*) prefix=$outer/ ;;
	esac

	[[ $inner == "$outer" || $inner == "$prefix"* ]]
}

# One inside the other: with --recursive the walk of the outer directory
# descends into the inner one, where every file is then also looked for at a
# doubled-up relative path that is not there. Without --recursive it is merely
# confusing. Neither is worth working out the answer to.
if inside "$A" "$B" || inside "$B" "$A"; then
	to_die "one directory is inside the other: $A and $B"
fi

to_counters_reset
to_depth_args
to_prompt_ready

# The walk is over DIR_A: those are the files whose timestamps are the truth.
#
# find prints "$A/<relative path>", so stripping that prefix gives the relative
# path without needing realpath --relative-to, which BusyBox has not got. The
# normalisation above is what makes that prefix reliable.
found=0
while IFS= read -r -d '' source; do
	found=1

	rel=${source#"$A/"}
	target=$B/$rel

	# The counterpart has to be a regular file and not a symlink. Setting a
	# timestamp through a symlink would change the target's, which is a file in
	# some third directory that this run was never asked about.
	if [[ -L $target ]]; then
		TOOL_SKIPPED=$(( TOOL_SKIPPED + 1 ))
		to_warn "counterpart is a symlink, skipping: $rel"
		continue
	fi
	if [[ ! -f $target ]]; then
		TOOL_SKIPPED=$(( TOOL_SKIPPED + 1 ))
		to_warn "no counterpart in DIR_B, skipping: $rel"
		continue
	fi

	if ! from=$(to_mtime_epoch "$source"); then
		TOOL_FAILED=$(( TOOL_FAILED + 1 ))
		to_warn "cannot read the timestamp of $rel in DIR_A, skipping"
		continue
	fi
	if ! was=$(to_mtime_epoch "$target"); then
		TOOL_FAILED=$(( TOOL_FAILED + 1 ))
		to_warn "cannot read the timestamp of $rel in DIR_B, skipping"
		continue
	fi

	# Whole seconds, which is what stat can promise everywhere. A file that
	# differs only in its sub-second part is reported as already in step and
	# left alone: it is the same second either way, and re-touching it would
	# report a change where there is not one worth making.
	if [[ $from == "$was" ]]; then
		TOOL_SKIPPED=$(( TOOL_SKIPPED + 1 ))
		continue
	fi

	stamp=$(to_mtime_stamp "$source") || stamp=$from

	if (( TOOL_DRY_RUN )); then
		printf 'would set %s to %s\n' "$target" "$stamp"
		TOOL_PLANNED=$(( TOOL_PLANNED + 1 ))
		continue
	fi

	if (( TOOL_INTERACTIVE )); then
		if [[ ! -e /dev/fd/3 ]]; then
			to_warn "interactive mode needs to_prompt_ready before the loop; skipping: $rel"
			TOOL_SKIPPED=$(( TOOL_SKIPPED + 1 ))
			continue
		fi

		# fd 3, never stdin: stdin belongs to the file list right now.
		if ! read -r -p "set '$target' to $stamp? [y/N] " reply <&3; then
			# End of input. Treat as "no" rather than aborting the batch.
			reply=""
			printf '\n'
		fi
		case ${reply,,} in
			y | yes) ;;
			*)
				TOOL_SKIPPED=$(( TOOL_SKIPPED + 1 ))
				continue
				;;
		esac
	fi

	# -r rather than -d @epoch: it needs no date parsing at all, which is the
	# one part of this that has to work on a machine whose date cannot read
	# what stat prints.
	if ! touch -r "$source" -- "$target"; then
		TOOL_FAILED=$(( TOOL_FAILED + 1 ))
		to_warn "could not set the timestamp, skipping: $rel"
		continue
	fi

	TOOL_CHANGED=$(( TOOL_CHANGED + 1 ))
	printf 'set %s to %s\n' "$target" "$stamp"

	# The timestamp DIR_B had before it was overwritten, which is the only way
	# back: nothing was moved, so there is nothing to move back. Whole seconds,
	# because that is what touch can be handed again without asking date to
	# interpret stat's output.
	if [[ -n $TOOL_LOG ]]; then
		printf '%s\t%s\n' "$target" "$was" >>"$TOOL_LOG" ||
			to_warn "could not append to undo log: $TOOL_LOG"
	fi
done < <(find "$A" ${TOOL_DEPTH[@]+"${TOOL_DEPTH[@]}"} -type f -print0)

# A directory with nothing at the depth asked for is a mistyped path more often
# than it is a deliberate request to do nothing, and "0 changed, 0 skipped" reads
# like success. Said before DIR_B is walked, so the walk below cannot turn a run
# with nothing to do into a green one.
#
# The two reasons are named separately, because "no files in DIR_A" said about a
# directory whose files are one level down sends the reader looking for a
# mistyped path instead of reaching for --recursive.
if (( ! found )); then
	# A probe, not a value: what matters is whether the read found anything, and
	# `deeper` is never looked at. `read` rather than `find -quit`, which is a GNU
	# extension -- this tool is written to run where find is BusyBox.
	if IFS= read -r -d '' deeper < <(find "$A" -type f -print0); then
		to_warn "no files in DIR_A one level deep, try --recursive: $A"
	else
		to_warn "no files in DIR_A: $A"
	fi
	exit "$TOOL_EX_USAGE"
fi

# The other direction. Nothing is changed here, so there is nothing to prompt
# about; it is reported because a file in one directory with nothing at the same
# path in the other is the one way two copies of the same tree can quietly
# disagree, and the pairing above cannot see it.
while IFS= read -r -d '' orphan; do
	rel=${orphan#"$B/"}
	# A symlink at that path in DIR_A counts as nothing there, because the walk
	# above could not see it either. Saying so is the point of this loop: a file
	# in DIR_B that DIR_A has no usable file for is the disagreement worth
	# reporting, and silence here would hide it behind a file that looks like it
	# is covered.
	if [[ -L $A/$rel ]]; then
		TOOL_SKIPPED=$(( TOOL_SKIPPED + 1 ))
		to_warn "only a symlink at this path in DIR_A, leaving alone: $rel"
		continue
	fi
	if [[ ! -f $A/$rel ]]; then
		TOOL_SKIPPED=$(( TOOL_SKIPPED + 1 ))
		to_warn "not in DIR_A, leaving alone: $rel"
	fi
done < <(find "$B" ${TOOL_DEPTH[@]+"${TOOL_DEPTH[@]}"} -type f -print0)

status=$TOOL_EX_OK
to_summary '' 'changed' 'to change' || status=$?

if [[ -n $TOOL_LOG ]]; then
	# Forward order, not last-to-first as the rename log wants. Each record
	# here sets one file to one timestamp, and no record depends on another, so
	# there is no sequence to get wrong. $epoch and $path are escaped so this
	# shell does not expand them into empty strings first.
	cat <<-EOF
		$TOOL_PROG: reverse with:
		  while IFS=$'\t' read -r path epoch; do touch -d "@\$epoch" -- "\$path"; done < $TOOL_LOG
	EOF
fi

exit "$status"
