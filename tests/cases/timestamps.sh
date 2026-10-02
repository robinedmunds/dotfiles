#!/usr/bin/env bash
#
# sync-timestamps.sh: DIR_A is authoritative, DIR_B is corrected to match it.
#
# The fixtures live inside the throwaway Home, which is what lets these cases use
# the same "wrote nothing" snapshot the install.sh cases use: a run that changes
# a timestamp and nothing else still shows up as a change, because the snapshot
# carries modification times.

source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"

readonly TOOL=sync-timestamps.sh

# Two directories of the same two files, three years apart, so that a run which
# copies the wrong direction, or the wrong file, cannot look like a pass.
two_trees() {
	in_home 'a/one.txt' 644 'one'
	in_home 'a/two.jpg' 644 'two'
	in_home 'b/one.txt' 644 'one'
	in_home 'b/two.jpg' 644 'two'
	set_mtime 'a/one.txt' '2021-01-02 03:04:05'
	set_mtime 'a/two.jpg' '2021-02-03 04:05:06'
	set_mtime 'b/one.txt' '2019-01-02 03:04:05'
	set_mtime 'b/two.jpg' '2019-02-03 04:05:06'
}

# ---------------------------------------------------------------------------
# The promise
# ---------------------------------------------------------------------------

case_dry_run_changes_no_timestamp() {
	setup
	two_trees

	run_tool "$TOOL" --dry-run a b

	assert_rc 0 'exit 0'
	assert_out 'would set' 'each change is reported'
	assert_out '2 to change' 'and counted'
	assert_nothing_written 'not one timestamp moved'
}
test_case 'a dry run over two directories changes no timestamp' case_dry_run_changes_no_timestamp

case_dir_a_is_the_source_of_truth() {
	setup
	two_trees

	run_tool "$TOOL" a b

	assert_rc 0 'exit 0'
	assert_same_mtime 'a/one.txt' 'b/one.txt' 'b/one.txt took the time from DIR_A'
	assert_same_mtime 'a/two.jpg' 'b/two.jpg' 'b/two.jpg took the time from DIR_A'
	assert_mtime 'a/one.txt' '2021-01-02 03:04:05' "and DIR_A's own time is untouched"
	assert_out '2 changed' 'both are counted as changed'
}
test_case 'DIR_B is given the timestamps DIR_A has' case_dir_a_is_the_source_of_truth

# The tool this replaced took the earlier of two timestamps and gave it to both.
# There is no "earlier wins" here: a file in DIR_B that is older than its
# counterpart has its time moved forward, which is what DIR_A being the source of
# truth means.
case_dir_a_wins_even_when_dir_b_is_older() {
	setup
	in_home 'a/f.txt' 644 'f'
	in_home 'b/f.txt' 644 'f'
	set_mtime 'a/f.txt' '2024-06-07 08:09:10'
	set_mtime 'b/f.txt' '2001-01-01 00:00:00'

	run_tool "$TOOL" a b

	assert_rc 0 'exit 0'
	assert_mtime 'b/f.txt' '2024-06-07 08:09:10' 'the older file was moved forward'
}
test_case 'DIR_A wins even when DIR_B holds the older time' case_dir_a_wins_even_when_dir_b_is_older

case_a_second_run_changes_nothing() {
	setup
	two_trees
	run_tool "$TOOL" a b

	run_tool "$TOOL" a b

	assert_rc 0 'exit 0, because a run that finds everything in step is done'
	assert_out '0 changed' 'nothing changed the second time'
	assert_out '2 skipped' 'and both files are reported as already in step'
}
test_case 'running it twice changes nothing the second time' case_a_second_run_changes_nothing

# ---------------------------------------------------------------------------
# Pairing
# ---------------------------------------------------------------------------

case_file_only_in_dir_a_is_reported_and_not_created() {
	setup
	in_home 'a/lonely.txt' 644 'lonely'
	in_home 'b/kept.txt' 644 'kept'

	run_tool "$TOOL" a b

	assert_rc 0 'exit 0: a file with no counterpart is not a failure'
	assert_err 'no counterpart in DIR_B' 'it is reported'
	assert_err 'lonely.txt' 'by name'
	assert_absent 'b/lonely.txt' 'and nothing was created in DIR_B to receive it'
}
test_case 'a file only in DIR_A is reported, not copied over' case_file_only_in_dir_a_is_reported_and_not_created

case_file_only_in_dir_b_is_left_alone() {
	setup
	in_home 'a/f.txt' 644 'f'
	in_home 'b/f.txt' 644 'f'
	in_home 'b/extra.txt' 644 'extra'
	set_mtime 'b/extra.txt' '2019-09-09 09:09:09'

	run_tool "$TOOL" a b

	assert_rc 0 'exit 0: DIR_B is allowed to hold more than DIR_A'
	assert_err 'not in DIR_A' 'the extra file is reported'
	assert_mtime 'b/extra.txt' '2019-09-09 09:09:09' 'and its timestamp is left alone'
}
test_case 'a file only in DIR_B is reported and left alone' case_file_only_in_dir_b_is_left_alone

case_subdirectories_need_recursive() {
	setup
	in_home 'a/deep/f.txt' 644 'f'
	in_home 'b/deep/f.txt' 644 'f'
	set_mtime 'a/deep/f.txt' '2022-02-02 02:02:02'
	set_mtime 'b/deep/f.txt' '2018-08-08 08:08:08'

	run_tool "$TOOL" a b

	assert_rc 1 'exit 1, because nothing matched at the depth asked for'
	assert_mtime 'b/deep/f.txt' '2018-08-08 08:08:08' \
		'and the subdirectory was left exactly as it was'
	# "no files in DIR_A" said about a directory whose files are one level down
	# sends the reader looking for a mistyped path. The message has to name the
	# depth, and point at the flag that would get past it.
	assert_err 'no files in DIR_A one level deep' \
		'the message says the files are one level down'
	assert_err '--recursive' 'and points at the flag that would reach them'
}
test_case 'a file in a subdirectory is left alone without --recursive' case_subdirectories_need_recursive

case_recursive_reaches_subdirectories() {
	setup
	in_home 'a/deep/f.txt' 644 'f'
	in_home 'b/deep/f.txt' 644 'f'
	set_mtime 'a/deep/f.txt' '2022-02-02 02:02:02'
	set_mtime 'b/deep/f.txt' '2018-08-08 08:08:08'

	run_tool "$TOOL" --recursive a b

	assert_rc 0 'exit 0'
	assert_same_mtime 'a/deep/f.txt' 'b/deep/f.txt' '--recursive reached the subdirectory'
}
test_case '--recursive syncs files in subdirectories' case_recursive_reaches_subdirectories

case_a_filename_with_a_newline_is_one_file() {
	setup
	local awkward
	awkward=$(printf 'new\nline.txt')
	in_home "a/$awkward" 644 'awkward'
	in_home "b/$awkward" 644 'awkward'
	set_mtime "a/$awkward" '2022-05-05 05:05:05'
	set_mtime "b/$awkward" '2018-05-05 05:05:05'

	run_tool "$TOOL" a b

	assert_rc 0 'exit 0'
	assert_out '1 changed' 'the newline did not split one name into two files'
	assert_same_mtime "a/$awkward" "b/$awkward" 'and the one file was synced'
}
test_case 'a newline in a filename does not split it in two' case_a_filename_with_a_newline_is_one_file

# find -type f does not see a symlink, so nothing in DIR_A that is one is ever
# considered. The file in DIR_B that a symlink's name would have paired with is
# the proof: it has to be left exactly as it was.
case_a_symlink_in_dir_a_is_not_followed() {
	setup
	in_home 'a/real.txt' 644 'real'
	in_home 'a/alias.txt' 644 'alias'
	in_home 'b/real.txt' 644 'real'
	in_home 'b/alias.txt' 644 'alias'
	set_mtime 'a/real.txt' '2022-04-04 04:04:04'
	set_mtime 'a/alias.txt' '2022-04-04 04:04:04'
	set_mtime 'b/real.txt' '2018-04-04 04:04:04'
	set_mtime 'b/alias.txt' '2017-04-04 04:04:04'
	ln -sfn -- real.txt "$HOME_DIR/a/alias.txt"

	run_tool "$TOOL" a b

	assert_rc 0 'exit 0'
	assert_same_mtime 'a/real.txt' 'b/real.txt' 'the regular file in DIR_A was synced'
	assert_mtime 'b/alias.txt' '2017-04-04 04:04:04' \
		'the counterpart of the symlink was left alone, so it was never read as a source'
	# The walk over DIR_B is the only thing that can see this: DIR_A's own walk
	# never sees the symlink, so nothing reports it from that side.
	assert_err 'only a symlink at this path in DIR_A' \
		'and it is reported rather than passed over in silence'
}
test_case 'a symlink in DIR_A is passed over, not followed' case_a_symlink_in_dir_a_is_not_followed

# Setting a timestamp through a symlink changes the target's, and the target is a
# file in a third directory this run was never pointed at.
case_a_symlinked_counterpart_is_not_written_through() {
	setup
	in_home 'a/f.txt' 644 'f'
	in_home 'b/elsewhere.txt' 644 'elsewhere'
	set_mtime 'a/f.txt' '2022-07-07 07:07:07'
	set_mtime 'b/elsewhere.txt' '2018-07-07 07:07:07'
	ln -sfn -- elsewhere.txt "$HOME_DIR/b/f.txt"

	run_tool "$TOOL" a b

	assert_rc 0 'exit 0'
	assert_err 'counterpart is a symlink' 'the symlinked counterpart is reported'
	assert_mtime 'b/elsewhere.txt' '2018-07-07 07:07:07' \
		'and the file it points at keeps its own timestamp'
}
test_case 'a symlinked counterpart is not written through' case_a_symlinked_counterpart_is_not_written_through

# ---------------------------------------------------------------------------
# Refusals
# ---------------------------------------------------------------------------

case_the_same_directory_twice_is_refused() {
	setup
	in_home 'a/f.txt' 644 'f'

	run_tool "$TOOL" a a

	assert_rc 1 'exit 1'
	assert_err 'the two directories are the same' 'and it says why'
}
test_case 'the same directory twice is refused' case_the_same_directory_twice_is_refused

case_one_directory_inside_the_other_is_refused() {
	setup
	in_home 'a/inner/f.txt' 644 'f'

	run_tool "$TOOL" a a/inner
	assert_rc 1 'exit 1 when DIR_B is inside DIR_A'
	assert_err 'one directory is inside the other' 'and it says why'

	run_tool "$TOOL" a/inner a
	assert_rc 1 'exit 1 the other way round too'
	assert_err 'one directory is inside the other' 'with the same reason'
}
test_case 'one directory inside the other is refused' case_one_directory_inside_the_other_is_refused

# ".." and a trailing slash must not make two arguments look like one directory,
# which would otherwise pass the check above and then work through one tree twice.
case_two_spellings_of_one_directory_are_refused() {
	setup
	in_home 'a/f.txt' 644 'f'

	run_tool "$TOOL" a a/

	assert_rc 1 'exit 1'
	assert_err 'the two directories are the same' 'a trailing slash is not a second directory'
}
test_case 'two spellings of one directory are refused' case_two_spellings_of_one_directory_are_refused

case_a_file_is_not_a_directory() {
	setup
	in_home 'a/f.txt' 644 'f'

	run_tool "$TOOL" a a/f.txt

	assert_rc 1 'exit 1'
	assert_err 'not a directory' 'and it says which argument it was given'
}
test_case 'a file given where a directory belongs is refused' case_a_file_is_not_a_directory

case_the_wrong_number_of_arguments_is_refused() {
	setup
	in_home 'a/f.txt' 644 'f'
	in_home 'b/f.txt' 644 'f'

	run_tool "$TOOL" a
	assert_rc 1 'exit 1 for one directory'
	assert_err 'expected two directories, got 1' 'and it counts what it got'

	run_tool "$TOOL"
	assert_rc 1 'exit 1 for none'
}
test_case 'anything but two directories is refused' case_the_wrong_number_of_arguments_is_refused

# -C names the directory to work in, and this tool's arguments already are
# directories. Accepting the flag and then working somewhere else would be worse
# than refusing it.
case_the_directory_flag_is_refused() {
	setup
	in_home 'a/f.txt' 644 'f'
	in_home 'b/f.txt' 644 'f'
	set_mtime 'a/f.txt' '2022-08-08 08:08:08'
	set_mtime 'b/f.txt' '2018-08-08 08:08:08'

	run_tool "$TOOL" --directory a a b

	assert_rc 1 'exit 1'
	assert_err '--directory is not for this tool' 'and it says why'
	assert_mtime 'b/f.txt' '2018-08-08 08:08:08' 'nothing was changed on the way out'
}
test_case '--directory is refused rather than quietly ignored' case_the_directory_flag_is_refused

# A flag the tool does not know is a typo, most likely, and a tool that quietly
# treated it as a directory name would then look for a directory called --waln.
case_an_unknown_option_is_refused() {
	setup
	in_home 'a/f.txt' 644 'f'
	in_home 'b/f.txt' 644 'f'

	run_tool "$TOOL" --walnut a b

	assert_rc 1 'exit 1'
	assert_err 'unknown option: --walnut' 'and it names the option'
	assert_err 'try --help' 'and points at the help'
}
test_case 'an unknown option is refused rather than read as a directory' \
	case_an_unknown_option_is_refused

# The log is checked before the walk, not while it is being written, because the
# point of the log is the way back from a run that has already changed things.
case_an_undo_log_that_cannot_be_written_is_refused_first() {
	setup
	in_home 'a/f.txt' 644 'f'
	in_home 'b/f.txt' 644 'f'
	set_mtime 'a/f.txt' '2022-09-09 09:09:09'
	set_mtime 'b/f.txt' '2018-09-09 09:09:09'

	run_tool "$TOOL" --undo-log nowhere/undo.tsv a b

	assert_rc 1 'exit 1'
	assert_err 'cannot write undo log' 'and it says which file'
	assert_mtime 'b/f.txt' '2018-09-09 09:09:09' 'nothing was changed before the refusal'
}
test_case 'an undo log that cannot be written to is refused before any change' \
	case_an_undo_log_that_cannot_be_written_is_refused_first

case_an_empty_dir_a_is_an_error() {
	setup
	in_home 'b/f.txt' 644 'f'
	mkdir -p "$HOME_DIR/a"

	run_tool "$TOOL" a b

	assert_rc 1 'exit 1, because a mistyped path must not read as success'
	assert_err 'no files in DIR_A' 'and it says which directory held nothing'
}
test_case 'an empty DIR_A is an error rather than a quiet success' case_an_empty_dir_a_is_an_error

# ---------------------------------------------------------------------------
# Getting back
# ---------------------------------------------------------------------------

case_the_undo_log_records_the_time_that_was_there() {
	setup
	two_trees

	run_tool "$TOOL" --undo-log undo.tsv a b

	assert_rc 0 'exit 0'
	assert_out 'reverse with' 'the run prints its own reverse command'
	# The record is the file that was changed and the whole seconds it used to
	# carry: DIR_B's own timestamp before the run overwrote it.
	assert_file_has_line 'undo.tsv' \
		"$HOME_DIR/b/one.txt$(printf '\t')$(epoch_of '2019-01-02 03:04:05')" \
		'the first file records the time DIR_B had'
	assert_file_has_line 'undo.tsv' \
		"$HOME_DIR/b/two.jpg$(printf '\t')$(epoch_of '2019-02-03 04:05:06')" \
		'and the second records its own'
}
test_case 'the undo log records the timestamp it replaced' case_the_undo_log_records_the_time_that_was_there

# The reverse command is printed for a person to paste, so it is run here the way
# a person would run it: copied out of the output and handed to a shell.
case_the_reverse_command_puts_the_old_times_back() {
	setup
	two_trees

	run_tool "$TOOL" --undo-log "$HOME_DIR/undo.tsv" a b
	assert_rc 0 'the run itself worked'

	local reverse
	reverse=$(printf '%s\n' "$stdout" | sed -n 's/^[[:space:]]*//p' |
		grep -m1 '^while IFS=')
	if [[ -z $reverse ]]; then
		fail 'the reverse command is not in the output'
		return
	fi
	ok 'the reverse command is in the output, ready to paste'

	bash -c "$reverse"

	assert_rc 0 'the reverse command ran'
	assert_mtime 'b/one.txt' '2019-01-02 03:04:05' 'b/one.txt is back where it started'
	assert_mtime 'b/two.jpg' '2019-02-03 04:05:06' 'and so is b/two.jpg'
}
test_case 'the reverse command it prints puts the old times back' case_the_reverse_command_puts_the_old_times_back

# ---------------------------------------------------------------------------
# Asking
# ---------------------------------------------------------------------------

case_interactive_changes_only_what_is_agreed_to() {
	setup
	two_trees

	# One answer for two files: the second question finds nothing behind it and
	# is declined, which is the answer to a question nobody answered.
	run_tool_with_input $'y\n' "$TOOL" --interactive a b

	assert_rc 0 'exit 0'
	assert_out '1 changed' 'exactly the one file answered yes was changed'
	assert_out '1 skipped' 'and the other was left as it was'
}
test_case '--interactive changes only what is agreed to' case_interactive_changes_only_what_is_agreed_to

case_the_end_of_input_declines() {
	setup
	two_trees

	run_tool_with_input '' "$TOOL" --interactive a b

	assert_rc 0 'exit 0'
	assert_out '0 changed' 'nothing was changed'
	assert_out '2 skipped' 'both files were left as they were'
}
test_case 'running out of answers declines the rest' case_the_end_of_input_declines

# ---------------------------------------------------------------------------
# Failures
# ---------------------------------------------------------------------------

# Ownership, not permission, decides whether a timestamp can be set: the owner of
# a file can touch it whatever its mode says, so a read-only file is not a way to
# make this fail. A file this user does not own and cannot write is. /proc is the
# one place such a file can be relied on to exist, so the case skips elsewhere
# rather than pretending to have run.
case_a_timestamp_it_cannot_set_exits_2() {
	setup
	if [[ ! -r /proc/version ]]; then
		skip 'there is no /proc/version to try to write to'
		return
	fi
	if touch -d '2020-01-01 00:00:00' -- /proc/version 2>/dev/null; then
		skip 'this user can write /proc/version, so the refusal cannot be provoked'
		return
	fi

	in_home 'a/version' 644 'v'
	set_mtime 'a/version' '2020-01-01 00:00:00'

	run_tool "$TOOL" a /proc

	assert_rc 2 'exit 2, because one file could not be done'
	assert_err 'could not set the timestamp' 'and the failure is named'
	assert_out '1 failed' 'and counted'
}
test_case 'a timestamp it cannot set is counted and exits 2' case_a_timestamp_it_cannot_set_exits_2

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

case_help_says_which_directory_wins() {
	setup

	run_tool "$TOOL" --help

	assert_rc 0 '--help exits 0'
	assert_out 'Usage: sync-timestamps.sh' 'and prints a usage line naming itself'
	assert_out 'DIR_A is the source of truth' 'which says which directory wins'
	assert_out 'paired by relative path' 'and how two files are matched up'
	assert_out 'The undo log records one "path<TAB>old_epoch"' 'and what its log holds'
	assert_err '' 'nothing at all on stderr'
}
test_case '--help says which directory wins, and what the log holds' case_help_says_which_directory_wins

case_version_names_the_tool() {
	setup

	run_tool "$TOOL" --version

	assert_rc 0 '--version exits 0'
	assert_out 'sync-timestamps.sh 1' 'and prints its own name and version'
}
test_case '--version names the tool and its version' case_version_names_the_tool

# to_wants_help scans the whole argument list rather than stopping at the first
# thing it recognises, so --dry-run in front of --help still prints help. Pinned
# because that scan is the only reason it works.
case_dry_run_does_not_hide_help() {
	setup

	run_tool "$TOOL" --dry-run --help

	assert_rc 0 'exit 0'
	assert_out 'Usage:' 'help, rather than a complaint about --dry-run'
}
test_case '--dry-run in front of --help still prints help' case_dry_run_does_not_hide_help

run_cases
