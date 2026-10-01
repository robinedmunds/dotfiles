#!/usr/bin/env bash
#
# --dry-run: the promise that it reports everything and changes nothing.
# Most of these cases prove the second half by comparing the whole of Home,
# modification times included, before and after.

source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"

case_dry_run_on_a_fresh_home() {
	setup
	copy_install_script
	managed '.bashrc' 644 'export EDITOR=vim'
	managed '.config/nvim/init.lua' 644 'vim.o.number = true'
	managed '.local/bin/hello' 755 '#!/bin/sh
true'

	run --dry-run

	assert_rc 0 'exit 0'
	assert_out 'would install: ~/.bashrc' 'the first file is reported'
	assert_out 'would install: ~/.config/nvim/init.lua' 'and the second'
	assert_out 'dry run: nothing was written' 'and it says so'
	assert_nothing_written 'Home is untouched, no directories created either'
	assert_nothing_outside_home 'and nothing outside Home either'
}
test_case 'a dry run of a fresh Home writes nothing at all' case_dry_run_on_a_fresh_home

case_dry_run_reports_the_diff_before_deciding() {
	setup
	copy_install_script
	managed '.bashrc' 644 'export EDITOR=vim'
	in_home '.bashrc' 644 'export EDITOR=emacs'

	run --dry-run

	assert_rc 2 'exit 2, because Home would not be in sync'
	assert_out 'installed: ~/.bashrc' 'the diff is labelled with the two paths'
	assert_out 'repository: home/.bashrc' 'and names the repository side'
	assert_out '-export EDITOR=emacs' 'showing what is in Home now'
	assert_out '+export EDITOR=vim' 'and what the repository wants'
	assert_out 'would prompt before overwriting: ~/.bashrc' \
		'and says it would have asked'
	assert_out 'would change 1' 'the change is counted'
	assert_content '.bashrc' 'export EDITOR=emacs' 'nothing was overwritten'
	assert_nothing_written 'and nothing at all was written'
}
test_case 'a dry run shows the diff it would have shown' \
	case_dry_run_reports_the_diff_before_deciding

# The asymmetry between a dry run and the run it predicts: --dry-run --yes
# reports drift as something that would change, and answers exit 2, while the
# real --yes run fixes it and answers 0. So a CI gate written as
# `install.sh --dry-run --yes` reports this machine as never current. Pinned
# here as the behaviour it has today.
case_dry_run_yes_disagrees_with_yes() {
	setup
	copy_install_script
	managed '.bashrc' 644 'export EDITOR=vim'
	in_home '.bashrc' 644 'export EDITOR=emacs'

	run --dry-run --yes

	assert_rc 2 'the dry run says exit 2'
	assert_out 'would overwrite: ~/.bashrc' 'it reports what --yes would do'
	assert_nothing_written 'and wrote nothing'

	run --yes

	assert_rc 0 'the real run says exit 0'
	assert_content '.bashrc' 'export EDITOR=vim' 'and really did overwrite'
}
test_case '--dry-run --yes exits 2 where --yes exits 0' case_dry_run_yes_disagrees_with_yes

case_dry_run_keep_existing() {
	setup
	copy_install_script
	managed '.bashrc' 644 'export EDITOR=vim'
	managed '.profile' 644 'repo profile'
	in_home '.bashrc' 644 'export EDITOR=emacs'

	run --dry-run --keep-existing

	assert_rc 2 'exit 2'
	assert_out 'would keep: ~/.bashrc' 'the drifted file would be kept'
	assert_out 'would install: ~/.profile' 'and the missing one installed'
	assert_content '.bashrc' 'export EDITOR=emacs' 'nothing was kept or installed'
	assert_nothing_written 'nothing was written'
}
test_case '--dry-run --keep-existing reports keeping' case_dry_run_keep_existing

case_dry_run_when_in_sync() {
	setup
	copy_install_script
	managed '.bashrc' 644 'export EDITOR=vim'
	in_home '.bashrc' 644 'export EDITOR=vim'

	run --dry-run

	assert_rc 0 'exit 0'
	assert_out 'in sync: ~/.bashrc' 'the file is in sync'
	assert_not_out 'would install' 'and there is nothing it would install'
	assert_not_out 'would prompt' 'and nothing it would ask about'
	assert_not_out 'would overwrite' 'and nothing it would overwrite'
	assert_nothing_written 'and nothing was written'
}
test_case 'a dry run of an in-sync Home exits 0 and promises nothing' \
	case_dry_run_when_in_sync

case_dry_run_reports_mode_changes() {
	setup
	copy_install_script
	managed '.bashrc' 644 'export EDITOR=vim'
	in_home '.bashrc' 600 'export EDITOR=vim'

	run --dry-run

	assert_rc 0 'exit 0, a mode fix is not Drift that needs a decision'
	assert_out 'would fix mode: ~/.bashrc' 'the mode fix is reported'
	assert_mode '.bashrc' 600 'and the mode was left alone'
	assert_nothing_written 'nothing was written'
}
test_case 'a dry run reports a mode fix without making it' case_dry_run_reports_mode_changes

case_dry_run_reports_a_symlink_replacement() {
	setup
	copy_install_script
	managed '.bashrc' 644 'export EDITOR=vim'
	home_link '.bashrc' "$SANDBOX/outside/mine"

	run --dry-run

	assert_rc 0 'exit 0'
	assert_out 'would replace symlink with regular file: ~/.bashrc' \
		'the replacement is reported'
	assert_symlink '.bashrc' 'and the symlink is still a symlink'
	assert_nothing_written 'nothing was written'
}
test_case 'a dry run reports a symlink replacement without making it' \
	case_dry_run_reports_a_symlink_replacement

case_dry_run_still_refuses() {
	setup
	copy_install_script
	managed '.bashrc' 644 'export EDITOR=vim'
	managed '.config/nvim/init.lua' 644 'vim.o.number = true'
	in_home '.config' 644 'a file in the way'

	run --dry-run

	assert_rc 1 'exit 1, a refusal still outranks everything'
	assert_err "not a directory: $HOME_DIR/.config" 'the refusal is reported'
	assert_out 'refused 1' 'and counted'
	assert_absent '.bashrc' 'and nothing was installed'
	assert_nothing_written 'nothing was written'
}
test_case 'a dry run still refuses what a real run would refuse' case_dry_run_still_refuses

case_dry_run_asks_nothing() {
	setup
	copy_install_script
	managed '.a-drifted' 644 'repo a'
	managed '.b-drifted' 644 'repo b'
	in_home '.a-drifted' 644 'home a'
	in_home '.b-drifted' 644 'home b'

	pty_run '' --dry-run || return

	assert_rc 2 'exit 2'
	assert_out 'would prompt before overwriting: ~/.a-drifted' 'the first is reported'
	assert_count '? [Y]es (default)' 0 'and no prompt was shown even with a terminal'
	assert_content '.a-drifted' 'home a' 'nothing was overwritten'
	assert_nothing_written 'nothing was written'
}
test_case 'a dry run asks nothing even with a terminal' case_dry_run_asks_nothing

run_cases
