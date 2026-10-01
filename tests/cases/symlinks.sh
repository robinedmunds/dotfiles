#!/usr/bin/env bash
#
# Symlinks, both directions (ADR 0004): a symlink in Home is replaced with a
# regular file and never written through, and a symlink under home/ in the
# repository is dereferenced on the way in.

source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"

case_symlink_in_home_is_replaced() {
	setup
	copy_install_script
	managed '.bashrc' 644 'export EDITOR=vim'
	target="$SANDBOX/outside/elsewhere"
	printf 'the original target\n' >"$target"
	home_link '.bashrc' "$target"

	run --yes

	assert_rc 0 'exit 0'
	assert_regular_file '.bashrc' 'the symlink became a regular file'
	assert_content '.bashrc' 'export EDITOR=vim' 'holding the repository content'
	assert_content_for "$target" 'the original target' \
		'the file the symlink pointed at was not written through'
	assert_out 'replaced symlink: ~/.bashrc' 'the replacement was reported'
	assert_nothing_outside_home 'and nothing outside Home changed'
}
test_case 'a symlink in Home is replaced, not written through' \
	case_symlink_in_home_is_replaced

case_symlink_to_a_directory_is_replaced() {
	setup
	copy_install_script
	managed '.config' 644 'now a file'
	target="$SANDBOX/outside/adirectory"
	mkdir -p "$target"
	printf 'inside\n' >"$target/keep"
	home_link '.config' "$target"

	run --yes

	assert_rc 0 'exit 0'
	assert_regular_file '.config' 'the symlink to a directory became a file'
	assert_content '.config' 'now a file' 'holding the repository content'
	assert_content_for "$target/keep" 'inside' 'the directory it pointed at is intact'
	assert_nothing_outside_home 'and nothing outside Home changed'
}
test_case 'a symlink in Home pointing at a directory is replaced' \
	case_symlink_to_a_directory_is_replaced

case_dangling_symlink_in_home_is_replaced() {
	setup
	copy_install_script
	managed '.bashrc' 644 'export EDITOR=vim'
	home_link '.bashrc' "$SANDBOX/nowhere-at-all"

	run --yes

	assert_rc 0 'exit 0'
	assert_regular_file '.bashrc' 'the dangling symlink became a regular file'
	assert_content '.bashrc' 'export EDITOR=vim' 'holding the repository content'
}
test_case 'a dangling symlink in Home is replaced' case_dangling_symlink_in_home_is_replaced

case_symlink_is_replaced_even_when_the_content_matches() {
	setup
	copy_install_script
	managed '.bashrc' 644 'export EDITOR=vim'
	# The link resolves to a file whose bytes already match the repository.
	same="$SANDBOX/outside/same"
	printf 'export EDITOR=vim\n' >"$same"
	home_link '.bashrc' "$same"

	run --yes

	assert_rc 0 'exit 0'
	assert_regular_file '.bashrc' 'the symlink is replaced anyway'
	assert_out 'replaced symlink' 'and the replacement is reported'
	assert_content_for "$same" 'export EDITOR=vim' 'the target is untouched'
}
test_case 'a symlink is replaced even when its content already matches' \
	case_symlink_is_replaced_even_when_the_content_matches

case_drifted_symlink_is_replaced_not_kept() {
	setup
	copy_install_script
	managed '.bashrc' 644 'export EDITOR=vim'
	target="$SANDBOX/outside/mine"
	printf 'what I actually want\n' >"$target"
	home_link '.bashrc' "$target"

	run --yes

	assert_rc 0 'exit 0'
	assert_regular_file '.bashrc' 'the symlink became a regular file'
	assert_content '.bashrc' 'export EDITOR=vim' 'holding the repository content'
	assert_content_for "$target" 'what I actually want' \
		'the file it pointed at kept its own content'
}
test_case '--yes replaces a drifted symlink rather than following it' \
	case_drifted_symlink_is_replaced_not_kept

case_keep_existing_still_replaces_a_symlink() {
	setup
	copy_install_script
	managed '.bashrc' 644 'export EDITOR=vim'
	target="$SANDBOX/outside/mine"
	printf 'what I actually want\n' >"$target"
	home_link '.bashrc' "$target"

	run --keep-existing

	assert_rc 0 'exit 0'
	assert_regular_file '.bashrc' 'the symlink was replaced, not kept'
	assert_content '.bashrc' 'export EDITOR=vim' 'holding the repository content'
	assert_content_for "$target" 'what I actually want' \
		'the file it pointed at was not written through'
}
test_case '--keep-existing replaces a symlink too' case_keep_existing_still_replaces_a_symlink

case_symlink_in_the_repository_is_dereferenced() {
	setup
	copy_install_script
	source_file="$SANDBOX/link-target"
	printf 'the real content\n' >"$source_file"
	managed_link 'aliased' "$source_file"

	run --yes

	assert_rc 0 'exit 0'
	assert_regular_file 'aliased' 'a regular file was installed'
	assert_content 'aliased' 'the real content' 'holding the target content'
	assert_nothing_outside_home 'and the target outside Home was left alone'
}
test_case 'a symlink under home/ is installed as a regular file' \
	case_symlink_in_the_repository_is_dereferenced

# Characterisation, not endorsement. install.sh reads the mode of the file it
# is about to copy with `stat -c %a`, and without -L that is the mode of the
# symlink, which is 777 on every filesystem. So a symlinked Managed File
# arrives world-writable rather than carrying the mode of its target. Fixing
# it is a one-word change to install.sh; until then this test pins what
# happens, so that fixing it cannot pass unnoticed.
case_symlink_takes_the_mode_of_the_link_not_the_target() {
	setup
	copy_install_script
	source_file="$SANDBOX/link-target"
	printf '#!/bin/sh\ntrue\n' >"$source_file"
	chmod 755 "$source_file"
	managed_link 'aliased-tool' "$source_file"

	run --yes

	assert_rc 0 'exit 0'
	assert_regular_file 'aliased-tool' 'and it is a regular file'
	assert_mode 'aliased-tool' 777 'the target is 755 but the link reads as 777'
}
test_case 'a dereferenced symlink takes the mode of the link, not the target' \
	case_symlink_takes_the_mode_of_the_link_not_the_target

run_cases
