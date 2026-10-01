#!/usr/bin/env bash
#
# Drift: a Managed File is in Home and does not match the repository. What
# happens to it under each flag, and what the exit code ends up saying.

source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"

case_yes_overwrites_drift() {
	setup
	copy_install_script
	managed '.bashrc' 644 'export EDITOR=vim'
	in_home '.bashrc' 644 'export EDITOR=emacs'

	run --yes

	assert_rc 0 'exit 0, so the machine ends up in sync'
	assert_content '.bashrc' 'export EDITOR=vim' 'the repository version won'
	assert_out 'overwrote: ~/.bashrc' 'the overwrite was reported'
	assert_out 'installed 0, in sync 0, mode fixed 0, overwritten 1, kept 0, refused 0' \
		'the counts are right'
}
test_case '--yes overwrites a drifted file' case_yes_overwrites_drift

case_yes_then_in_sync() {
	setup
	copy_install_script
	managed '.bashrc' 644 'export EDITOR=vim'
	in_home '.bashrc' 644 'export EDITOR=emacs'

	run --yes
	assert_rc 0 'the first run succeeds'
	run --yes

	assert_rc 0 'the second run exits 0'
	assert_out 'in sync: ~/.bashrc' 'and reports the file in sync'
	assert_nothing_written 'and touches nothing'
}
test_case 'after overwriting, the next run is in sync' case_yes_then_in_sync

case_keep_existing_keeps_drift() {
	setup
	copy_install_script
	managed '.bashrc' 644 'export EDITOR=vim'
	managed '.profile'
	in_home '.bashrc' 644 'export EDITOR=emacs'

	run --keep-existing

	assert_rc 2 'exit 2, because Home is not in sync'
	assert_content '.bashrc' 'export EDITOR=emacs' 'the drifted file was kept'
	assert_content '.profile' '.profile' 'the missing file was still installed'
	assert_out 'kept: ~/.bashrc' 'the keep was reported'
	assert_out 'installed 1, in sync 0, mode fixed 0, overwritten 0, kept 1, refused 0' \
		'the counts are right'
	assert_nothing_outside_home 'nothing outside Home was touched'
}
test_case '--keep-existing keeps drift but installs what is missing' \
	case_keep_existing_keeps_drift

case_keep_existing_when_in_sync() {
	setup
	copy_install_script
	managed '.bashrc' 644 'export EDITOR=vim'
	in_home '.bashrc' 644 'export EDITOR=vim'

	run --keep-existing

	assert_rc 0 'exit 0'
	assert_out 'in sync: ~/.bashrc' 'the file is in sync'
}
test_case '--keep-existing on an in-sync Home exits 0' case_keep_existing_when_in_sync

case_mode_drift_is_fixed_without_asking() {
	setup
	copy_install_script
	managed '.bashrc' 644 'export EDITOR=vim'
	managed 'private' 600 'secret-ish'
	in_home '.bashrc' 600 'export EDITOR=vim'
	in_home 'private' 644 'secret-ish'

	run --keep-existing

	assert_rc 0 'exit 0, a mode difference is not Drift that needs a decision'
	assert_mode '.bashrc' 644 'the loose mode was tightened'
	assert_mode 'private' 600 'the loose mode was tightened the other way'
	assert_content '.bashrc' 'export EDITOR=vim' 'the bytes were not touched'
	assert_out 'fixed mode: ~/.bashrc' 'the fix was reported'
	assert_out 'mode fixed 2' 'and counted'
	assert_count '? [Y]es (default)' 0 'nothing was asked'
}
test_case 'a mode difference is fixed silently, even under --keep-existing' \
	case_mode_drift_is_fixed_without_asking

case_missing_final_newline_is_drift() {
	setup
	copy_install_script
	managed_raw '.profile' 644 'export PATH=$PATH:~/bin'
	in_home_raw '.profile' 644 'export PATH=$PATH:~/bin
'

	run --yes

	assert_rc 0 'exit 0'
	assert_out 'overwrote: ~/.profile' 'a trailing newline counts as Drift'
}
test_case 'a trailing newline is part of the content' case_missing_final_newline_is_drift

case_binary_drift() {
	setup
	copy_install_script
	managed_bytes 'blob' 644 '\000\001\002repo\000'
	in_home_bytes 'blob' 644 '\000\001\002home\000'

	run --yes

	assert_rc 0 'exit 0'
	assert_out 'overwrote: ~/blob' 'a binary file is overwritten too'
	assert_matches 'blob' '\000\001\002repo\000' 'the repository bytes arrived'
	assert_count 'Binary files' 0 'no diff is printed when nothing is prompted'
}
test_case 'a binary file can drift and be overwritten' case_binary_drift

case_refusal_outranks_a_keep() {
	setup
	copy_install_script
	managed '.bashrc' 644 'export EDITOR=vim'
	managed '.config/nvim/init.lua' 644 'vim.o.number = true'
	in_home '.bashrc' 644 'export EDITOR=emacs'
	# A plain file where the repository wants a directory to descend through.
	in_home '.config' 644 'not a directory'

	run --keep-existing

	assert_rc 1 'exit 1, a refusal outranks a keep'
	assert_content '.bashrc' 'export EDITOR=emacs' 'the drifted file was kept'
	assert_out 'refused 1' 'the refusal was counted'
	assert_out 'kept 1' 'and so was the keep'
}
test_case 'a refusal outranks a keep in the exit code' case_refusal_outranks_a_keep

case_drift_and_a_missing_file_together() {
	setup
	copy_install_script
	managed '.a-drifted' 644 'repo a'
	managed '.b-missing' 644 'repo b'
	managed '.c-drifted' 644 'repo c'
	in_home '.a-drifted' 644 'home a'
	in_home '.c-drifted' 644 'home c'

	run --yes

	assert_rc 0 'exit 0'
	assert_content '.a-drifted' 'repo a' 'the first drifted file was overwritten'
	assert_content '.b-missing' 'repo b' 'the missing file was installed'
	assert_content '.c-drifted' 'repo c' 'the second drifted file was overwritten'
	assert_out 'installed 1, in sync 0, mode fixed 0, overwritten 2, kept 0, refused 0' \
		'the counts add up'
}
test_case 'drifted and missing files are handled in one run' \
	case_drift_and_a_missing_file_together

run_cases
