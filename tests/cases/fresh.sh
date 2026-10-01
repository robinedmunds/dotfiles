#!/usr/bin/env bash
#
# The fresh-machine path: nothing in Home yet. This is the run that has to
# work without asking anything, because there is nothing to ask about.

source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"

case_fresh_install_is_silent() {
	setup
	copy_install_script
	managed '.bashrc' 644 'export EDITOR=vim'
	managed '.profile'
	managed '.config/nvim/init.lua' 644 'vim.o.number = true'

	run --yes

	assert_rc 0 'exit 0'
	assert_content '.bashrc' 'export EDITOR=vim' 'a top-level file arrived'
	assert_content '.profile' '.profile' 'and another'
	assert_content '.config/nvim/init.lua' 'vim.o.number = true' \
		'a nested file arrived'
	assert_out 'installed: ~/.bashrc' 'the install was reported'
	assert_out 'installed 3, in sync 0, mode fixed 0, overwritten 0, kept 0, refused 0' \
		'the counts are right'
	assert_not_out 'overwrite' 'nothing was asked'
	assert_not_err 'warning' 'nothing was refused'
}
test_case 'a fresh Home is installed without asking' case_fresh_install_is_silent

case_fresh_install_asks_nothing_interactively() {
	setup
	copy_install_script
	managed '.bashrc'
	managed '.profile'

	# A pty, but no answers: if the script prompts at all this times out.
	pty_run '' || return

	assert_rc 0 'exit 0'
	assert_out 'installed 2' 'both files were installed'
	assert_count '? [Y]es (default)' 0 'no prompt was shown'
}
test_case 'a fresh Home asks nothing even with a terminal' \
	case_fresh_install_asks_nothing_interactively

case_executable_bit_survives() {
	setup
	copy_install_script
	managed '.local/bin/hello' 755 '#!/bin/sh
echo hello from home'
	managed '.bashrc' 600 'private'
	managed 'plain' 444 'read only'

	run --yes

	assert_rc 0 'exit 0'
	assert_mode '.local/bin/hello' 755 'an executable stays executable'
	assert_mode '.bashrc' 600 'a private file stays private'
	assert_mode 'plain' 444 'a read-only file stays read-only'
}
test_case 'the mode of each file is preserved exactly' case_executable_bit_survives

case_installed_script_runs() {
	setup
	copy_install_script
	managed '.local/bin/hello' 755 '#!/bin/sh
echo hello from home'

	run --yes
	output=$("$HOME_DIR/.local/bin/hello")

	assert_rc 0 'exit 0'
	assert_content '.local/bin/hello' '#!/bin/sh
echo hello from home' 'the script arrived'
	[[ $output == 'hello from home' ]] \
		&& ok 'and runs' \
		|| fail "and runs -- it printed '$output'"
}
test_case 'an installed script is runnable' case_installed_script_runs

case_ambient_umask_does_not_leak_into_files() {
	setup
	copy_install_script
	managed '.bashrc' 644 'export EDITOR=vim'
	managed '.local/bin/tool' 755 '#!/bin/sh
true'

	(umask 077 && run --yes)

	assert_rc 0 'exit 0'
	assert_mode '.bashrc' 644 'a 644 file is 644 under a hostile umask'
	assert_mode '.local/bin/tool' 755 'a 755 file is 755 under a hostile umask'
}
test_case 'the ambient umask does not change installed file modes' \
	case_ambient_umask_does_not_leak_into_files

case_second_run_changes_nothing() {
	setup
	copy_install_script
	managed '.bashrc' 644 'export EDITOR=vim'
	managed '.local/bin/hello' 755 '#!/bin/sh
echo hi'

	run --yes
	assert_rc 0 'the first run succeeds'
	HOME_BEFORE=$(snapshot)

	run --yes

	assert_rc 0 'the second run also exits 0, which is how you know this machine is current'
	assert_out 'in sync: ~/.bashrc' 'the first file is reported in sync'
	assert_out 'in sync: ~/.local/bin/hello' 'and the second'
	assert_out 'installed 0, in sync 2' 'nothing was installed again'
	assert_count '? [Y]es (default)' 0 'nothing was asked'
	assert_nothing_written 'not one byte was rewritten'
}
test_case 'running twice is in sync the second time' case_second_run_changes_nothing

case_run_from_anywhere() {
	setup
	copy_install_script
	managed '.bashrc'
	workdir="$SANDBOX/somewhere/else"
	mkdir -p "$workdir"

	run_cmd env HOME="$HOME_DIR" LC_ALL=C bash -c \
		"cd '$workdir' && '$INSTALL_SH_UNDER_TEST' --yes"

	assert_rc 0 'exit 0'
	assert_content '.bashrc' '.bashrc' 'the file was installed'
}
test_case 'the script works from any working directory' case_run_from_anywhere

run_cases
