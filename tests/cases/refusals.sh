#!/usr/bin/env bash
#
# The cases where the script refuses: something about Home makes writing the
# Managed File either impossible or unsafe. A refusal is reported and the run
# carries on, so every one of these also has to prove that the files it did
# not refuse were installed and that nothing outside Home was written.

source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"

case_directory_where_a_file_belongs() {
	setup
	copy_install_script
	managed '.bashrc' 644 'export EDITOR=vim'
	in_home '.bashrc/keep-me' 644 'my own notes'
	mkdir -p "$HOME_DIR/.config/nvim"
	managed '.config/nvim/init.lua' 644 'vim.o.number = true'

	run --yes

	assert_rc 1 'exit 1'
	assert_err 'is a directory but the repository has a file there' \
		'says what is in the way'
	assert_err '~/.bashrc' 'and names the path'
	assert_content '.bashrc/keep-me' 'my own notes' 'the directory is left intact'
	assert_content '.config/nvim/init.lua' 'vim.o.number = true' \
		'the other file is still installed'
	assert_nothing_outside_home 'nothing outside Home was touched'
}
test_case 'a directory where a Managed File belongs is refused' \
	case_directory_where_a_file_belongs

case_file_where_a_directory_belongs() {
	setup
	copy_install_script
	managed '.bashrc' 644 'export EDITOR=vim'
	managed '.config/nvim/init.lua' 644 'vim.o.number = true'
	in_home '.config' 644 'this is a file, not a directory'

	run --yes

	assert_rc 1 'exit 1'
	assert_err "not a directory: $HOME_DIR/.config" 'says the ancestor is in the way'
	assert_content '.config' 'this is a file, not a directory' \
		'the blocking file is unchanged'
	assert_content '.bashrc' 'export EDITOR=vim' 'the unrelated file is installed'
	assert_nothing_outside_home 'nothing outside Home was touched'
}
test_case 'a plain file where a directory is needed is refused' \
	case_file_where_a_directory_belongs

case_symlinked_directory_is_never_written_through() {
	setup
	copy_install_script
	managed '.bashrc' 644 'export EDITOR=vim'
	managed '.config/nvim/init.lua' 644 'vim.o.number = true'
	# The decoy lives outside Home, exactly where a symlinked ancestor would
	# otherwise send the write.
	decoy="$SANDBOX/outside/decoy"
	mkdir -p "$decoy"
	printf 'untouched\n' >"$decoy/marker"
	home_link '.config' "$decoy"

	run --yes

	assert_rc 1 'exit 1'
	assert_err "symlink: $HOME_DIR/.config" 'says the ancestor is a symlink'
	assert_err 'refusing to install' 'and that it refused'
	assert_err '~/.config/nvim/init.lua' 'naming the file it gave up on'
	assert_absent '.config/nvim/init.lua' 'nothing was installed through the symlink'
	[[ -e $decoy/nvim ]] \
		&& fail 'the symlink target gained a directory' \
		|| ok 'the directory outside Home was never created'
	assert_content '.bashrc' 'export EDITOR=vim' 'the unrelated file is installed'
	assert_nothing_outside_home 'and nothing outside Home changed at all'
}
test_case 'a symlinked ancestor directory is refused, not written through' \
	case_symlinked_directory_is_never_written_through

case_symlinked_directory_in_dry_run() {
	setup
	copy_install_script
	managed '.config/nvim/init.lua' 644 'vim.o.number = true'
	decoy="$SANDBOX/outside/decoy"
	mkdir -p "$decoy"
	home_link '.config' "$decoy"

	run --dry-run

	assert_rc 1 'exit 1'
	assert_err "symlink: $HOME_DIR/.config" 'a dry run reports the refusal too'
	assert_absent '.config/nvim/init.lua' 'and still writes nothing'
	[[ -e $decoy/nvim ]] \
		&& fail 'the symlink target gained a directory' \
		|| ok 'the directory outside Home was never created'
}
test_case 'a dry run refuses a symlinked ancestor without touching it' \
	case_symlinked_directory_in_dry_run

case_dangling_symlink_in_the_repository() {
	setup
	copy_install_script
	managed '.bashrc' 644 'export EDITOR=vim'
	managed_link 'broken' "$SANDBOX/nowhere-at-all"

	run --yes

	assert_rc 1 'exit 1'
	assert_err 'home/broken is a symlink that does not resolve to a file' \
		'says the symlink is unusable'
	assert_out 'refused 1' 'and counts the refusal'
	assert_content '.bashrc' 'export EDITOR=vim' 'the rest still installs'
}
test_case 'a symlink in home/ that resolves to nothing is refused' \
	case_dangling_symlink_in_the_repository

case_several_refusals_are_all_reported() {
	setup
	copy_install_script
	managed '.a-directory-clash/nested' 644 'x'
	managed '.b-directory-clash/nested' 644 'x'
	managed '.c-fine' 644 'fine'
	in_home '.a-directory-clash' 644 'a file in the way'
	in_home '.b-directory-clash' 644 'a file in the way'

	run --yes

	assert_rc 1 'exit 1'
	assert_err '~/.a-directory-clash' 'the first refusal is reported'
	assert_err '~/.b-directory-clash' 'the second is reported too'
	assert_out 'refused 2' 'both are counted'
	assert_content '.c-fine' 'fine' 'and the run carried on past them'
}
test_case 'every refusal in a run is reported, not just the first' \
	case_several_refusals_are_all_reported

case_nothing_is_deleted_from_home() {
	setup
	copy_install_script
	managed '.bashrc' 644 'export EDITOR=vim'
	in_home '.something-unmanaged' 644 'not in the repository'
	in_home 'notes/todo.txt' 644 'buy milk'

	run --yes

	assert_rc 0 'exit 0'
	assert_content '.something-unmanaged' 'not in the repository' \
		'an unmanaged file is left alone'
	assert_content 'notes/todo.txt' 'buy milk' 'and so is a file in an unmanaged directory'
}
test_case 'nothing is ever deleted from Home' case_nothing_is_deleted_from_home

run_cases
