#!/usr/bin/env bash
#
# The prompt itself. These cases need a terminal, so they go through the pty
# driver; without one the script refuses to guess and there is nothing to
# test. If python3 is missing they are skipped and counted as skipped.

source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"

PROMPT='? [Y]es (default)'

case_enter_overwrites() {
	setup
	copy_install_script
	managed '.bashrc' 644 'export EDITOR=vim'
	in_home '.bashrc' 644 'export EDITOR=emacs'

	pty_run $'\n' || return

	assert_rc 0 'exit 0, so the machine ends up in sync'
	assert_out "$PROMPT" 'the prompt was shown'
	assert_out 'overwrote: ~/.bashrc' 'and the default answer overwrote'
	assert_content '.bashrc' 'export EDITOR=vim' 'the repository version won'
}
test_case 'plain Enter takes the default and overwrites' case_enter_overwrites

case_yes_spelled_out_overwrites() {
	setup
	copy_install_script
	managed '.bashrc' 644 'export EDITOR=vim'
	in_home '.bashrc' 644 'export EDITOR=emacs'

	pty_run $'yes\n' || return

	assert_rc 0 'exit 0'
	assert_content '.bashrc' 'export EDITOR=vim' 'the file was overwritten'
}
test_case 'the answer can be spelled out' case_yes_spelled_out_overwrites

case_no_keeps() {
	setup
	copy_install_script
	managed '.bashrc' 644 'export EDITOR=vim'
	in_home '.bashrc' 644 'export EDITOR=emacs'

	pty_run $'n\n' || return

	assert_rc 2 'exit 2, because Home is not in sync afterwards'
	assert_out 'kept: ~/.bashrc' 'the file was kept'
	assert_content '.bashrc' 'export EDITOR=emacs' 'with my version intact'
}
test_case '"n" keeps the file I have' case_no_keeps

case_all_stops_asking() {
	setup
	copy_install_script
	managed '.a-drifted' 644 'repo a'
	managed '.b-drifted' 644 'repo b'
	managed '.c-missing' 644 'repo c'
	in_home '.a-drifted' 644 'home a'
	in_home '.b-drifted' 644 'home b'

	pty_run $'a\n' || return

	assert_rc 0 'exit 0'
	assert_count "$PROMPT" 1 '"a" was asked about once and never again'
	assert_out 'overwrote: ~/.a-drifted' 'the first file was overwritten'
	assert_out 'overwrote: ~/.b-drifted' 'the second was overwritten without asking'
	assert_out 'installed: ~/.c-missing' 'and the missing one was installed'
	assert_content '.a-drifted' 'repo a' 'the first file has the repository content'
	assert_content '.b-drifted' 'repo b' 'and so does the second'
}
test_case '"a" overwrites everything for the rest of the run' case_all_stops_asking

case_quit_stops_the_run() {
	setup
	copy_install_script
	managed '.a-drifted' 644 'repo a'
	managed '.b-drifted' 644 'repo b'
	managed '.c-missing' 644 'repo c'
	in_home '.a-drifted' 644 'home a'
	in_home '.b-drifted' 644 'home b'

	pty_run $'q\n' || return

	assert_rc 2 'exit 2, because the run stopped short'
	assert_out 'stopped, the rest of the repository was not installed' \
		'it says the rest was left alone'
	assert_content '.a-drifted' 'home a' 'the file it was asked about is untouched'
	assert_content '.b-drifted' 'home b' 'nothing after the quit was installed'
	assert_absent '.c-missing' 'including a file that was merely missing'
}
test_case '"q" stops the run where it stands' case_quit_stops_the_run

case_quit_reports_the_stop_only_once() {
	setup
	copy_install_script
	managed '.a-drifted' 644 'repo a'
	managed '.b-drifted' 644 'repo b'
	in_home '.a-drifted' 644 'home a'
	in_home '.b-drifted' 644 'home b'

	pty_run $'q\n' || return

	assert_rc 2 'exit 2'
	assert_count 'the rest of the repository was not installed' 1 \
		'the stop is reported once, not once per remaining file'
}
test_case 'stopping early is reported once' case_quit_reports_the_stop_only_once

case_end_of_input_is_not_guessed_at() {
	setup
	copy_install_script
	managed '.a-drifted' 644 'repo a'
	managed '.b-drifted' 644 'repo b'
	in_home '.a-drifted' 644 'home a'
	in_home '.b-drifted' 644 'home b'

	# EOT at the prompt: input ran out with an answer still owed.
	pty_run $'\x04' || return

	assert_rc 2 'exit 2, not a guess'
	assert_content '.a-drifted' 'home a' 'nothing was overwritten'
	assert_content '.b-drifted' 'home b' 'and nothing after it was installed'
	assert_out 'stopped' 'and it says it stopped'
}
test_case 'running out of input is treated as quitting, not as Enter' \
	case_end_of_input_is_not_guessed_at

case_unrecognised_answer_asks_again() {
	setup
	copy_install_script
	managed '.bashrc' 644 'export EDITOR=vim'
	in_home '.bashrc' 644 'export EDITOR=emacs'

	pty_run $'maybe\nn\n' || return

	assert_rc 2 'exit 2, because the answer given in the end was "n"'
	assert_out 'unrecognised answer, try again' 'the bad answer was refused'
	assert_count "$PROMPT" 2 'and the question was asked again'
	assert_content '.bashrc' 'export EDITOR=emacs' 'the second answer was the one used'
}
test_case 'an unrecognised answer re-asks the question' \
	case_unrecognised_answer_asks_again

case_the_diff_comes_before_the_question() {
	setup
	copy_install_script
	managed '.bashrc' 644 'export EDITOR=vim'
	in_home '.bashrc' 644 'export EDITOR=emacs'

	pty_run $'n\n' || return

	assert_rc 2 'exit 2'
	assert_out 'installed: ~/.bashrc' 'the diff is labelled with the two paths'
	assert_out "repository: home/.bashrc" 'naming the repository side'
	assert_out '-export EDITOR=emacs' 'showing what is in Home now'
	assert_out '+export EDITOR=vim' 'and what the repository wants'
	assert_before '+export EDITOR=vim' "$PROMPT" 'the diff is shown before the question'
}
test_case 'the diff is shown before the question is asked' \
	case_the_diff_comes_before_the_question

case_one_answer_per_file() {
	setup
	copy_install_script
	managed '.a-drifted' 644 'repo a'
	managed '.b-drifted' 644 'repo b'
	managed '.c-drifted' 644 'repo c'
	in_home '.a-drifted' 644 'home a'
	in_home '.b-drifted' 644 'home b'
	in_home '.c-drifted' 644 'home c'

	pty_run $'n\n\ny\n' || return

	assert_rc 2 'exit 2, one file was kept'
	assert_count "$PROMPT" 3 'every drifted file was asked about'
	assert_content '.a-drifted' 'home a' 'the first was kept'
	assert_content '.b-drifted' 'repo b' 'the second was overwritten by Enter'
	assert_content '.c-drifted' 'repo c' 'the third was overwritten explicitly'
}
test_case 'each answer goes to the file that was asked about' case_one_answer_per_file

case_prompt_shows_the_path_in_tilde_form() {
	setup
	copy_install_script
	managed '.config/nvim/init.lua' 644 'vim.o.number = true'
	in_home '.config/nvim/init.lua' 644 'vim.o.number = false'

	pty_run $'n\n' || return

	assert_rc 2 'exit 2'
	assert_out 'overwrite ~/.config/nvim/init.lua?' 'the question names the file'
}
test_case 'the question names the file in tilde form' \
	case_prompt_shows_the_path_in_tilde_form

run_cases
