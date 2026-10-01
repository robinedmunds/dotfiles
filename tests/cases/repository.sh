#!/usr/bin/env bash
#
# What counts as a Managed File: which paths under home/ get installed at
# all, and which are left behind as tooling.

source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"

case_no_home_directory() {
	setup
	copy_install_script

	run --yes

	assert_rc 0 'exit 0'
	assert_out 'no home/ directory' 'says there is nothing to do'
	assert_out 'nothing to install' 'and that it is not an error'
	assert_nothing_written 'wrote nothing'
}
test_case 'a repository with no home/ installs nothing' case_no_home_directory

case_empty_home_directory() {
	setup
	copy_install_script
	mkdir -p "$REPO/home/.config/nvim"

	run --yes

	assert_rc 0 'exit 0'
	assert_out 'contains no files' 'says there is nothing to do'
	assert_nothing_written 'wrote nothing, empty directories included'
}
test_case 'an empty home/ installs nothing' case_empty_home_directory

case_nested_git_is_not_a_managed_file() {
	setup
	copy_install_script
	managed '.bashrc'
	managed '.git/config' 644 'a git internal'
	managed '.config/nvim/.git/config' 644 'another git internal'
	managed '.config/nvim/init.lua'

	run --yes

	assert_rc 0 'exit 0'
	assert_absent '.git/config' 'the top-level .git is not installed'
	assert_absent '.config/nvim/.git/config' 'a nested .git is not installed'
	assert_content '.bashrc' '.bashrc' 'a file beside it still is'
	assert_content '.config/nvim/init.lua' '.config/nvim/init.lua' \
		'and one inside it too'
	assert_nothing_outside_home 'nothing outside Home was touched'
}
test_case 'a .git directory is never installed' case_nested_git_is_not_a_managed_file

case_other_hidden_files_are_managed() {
	setup
	copy_install_script
	managed '.bashrc'

	run --yes

	assert_rc 0 'exit 0'
	assert_content '.bashrc' '.bashrc' 'a dotfile is installed like any other'
}
test_case 'nothing but .git is excluded' case_other_hidden_files_are_managed

case_deeply_nested_parents_are_created() {
	setup
	copy_install_script
	managed 'a/b/c/d/deep-file'

	run --yes

	assert_rc 0 'exit 0'
	assert_exists 'a' 'the top directory was created'
	assert_exists 'a/b/c/d' 'and every level under it'
	assert_content 'a/b/c/d/deep-file' 'a/b/c/d/deep-file' 'the file arrived'
}
test_case 'missing parent directories are created' case_deeply_nested_parents_are_created

case_awkward_filenames() {
	setup
	copy_install_script
	managed 'with space'
	managed $'with\nnewline'
	managed '-leading-dash'
	managed 'café'
	managed "it's"
	managed 'a file with  spaces   inside'
	managed 'trailing space '

	run --yes

	assert_rc 0 'exit 0'
	assert_content 'with space' 'with space' 'a name with a space'
	assert_content $'with\nnewline' $'with\nnewline' 'a name with a newline in it'
	assert_content '-leading-dash' '-leading-dash' 'a name that looks like a flag'
	assert_content 'café' 'café' 'a non-ASCII name'
	assert_content "it's" "it's" 'a quote in the name'
	assert_content 'a file with  spaces   inside' 'a file with  spaces   inside' \
		'consecutive spaces'
	assert_content 'trailing space ' 'trailing space ' 'a trailing space'
}
test_case 'awkward file names survive the round trip' case_awkward_filenames

case_empty_and_large_files() {
	setup
	copy_install_script
	mkdir -p "$REPO/home"
	: >"$REPO/home/empty"
	mkdir -p "$REPO/home/big"
	head -c 200000 /dev/zero | tr '\0' 'x' >"$REPO/home/big/large"

	run --yes

	assert_rc 0 'exit 0'
	assert_exists 'empty' 'a zero-byte file is installed'
	assert_content 'big/large' "$(head -c 200000 /dev/zero | tr '\0' 'x')" \
		'a large file arrives intact'
	assert_nothing_written 'and nothing changed afterwards'
}
test_case 'empty and large files install correctly' case_empty_and_large_files

run_cases
