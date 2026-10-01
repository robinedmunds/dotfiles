#!/usr/bin/env bash
#
# Everything the script decides before it looks at a single file: options,
# its idea of where Home is, its dependencies, and whether it has somewhere
# to ask a question.

source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"

# A PATH holding every tool the script needs, except diff.
shim_path_without_diff() {
	local name
	mkdir -p "$SANDBOX/bin"
	for name in bash dirname find sort cmp stat mkdir cp chmod rm cat; do
		ln -s -- "$(command -v "$name")" "$SANDBOX/bin/$name"
	done
	printf '%s' "$SANDBOX/bin"
}

case_help_describes_itself() {
	setup
	copy_install_script

	run --help

	assert_rc 0 'exit 0'
	assert_out 'Usage: install.sh' 'names the script'
	assert_out '--dry-run' 'documents --dry-run'
	assert_out '--yes' 'documents --yes'
	assert_out '--keep-existing' 'documents --keep-existing'
	assert_out 'Exit codes:' 'documents the exit codes'
	assert_not_err 'error:' 'says nothing on stderr'
}
test_case 'help describes itself and exits cleanly' case_help_describes_itself

case_unknown_option() {
	setup
	copy_install_script

	run --nonsense

	assert_rc 1 'exit 1'
	assert_err 'unknown option: --nonsense' 'names the offending option'
	assert_err 'Usage: install.sh' 'usage goes to stderr, not stdout'
	assert_not_out 'installed:' 'and nothing goes to stdout'
}
test_case 'an unknown option is a usage error' case_unknown_option

case_contradictory_flags() {
	setup
	copy_install_script
	managed '.bashrc'

	run --yes --keep-existing

	assert_rc 1 'exit 1'
	assert_err 'contradict' 'says the two contradict'
	assert_not_out 'installed:' 'no work was reported'
}
test_case '--yes and --keep-existing are refused together' case_contradictory_flags

case_home_unset() {
	setup
	copy_install_script

	run_cmd env -u HOME LC_ALL=C "$INSTALL_SH_UNDER_TEST" --dry-run

	assert_rc 1 'exit 1'
	assert_err 'HOME is not set' 'says why'
}
test_case 'an unset HOME is refused' case_home_unset

case_home_not_a_directory() {
	setup
	copy_install_script
	not_a_directory="$SANDBOX/not-a-directory"
	: >"$not_a_directory"

	run_cmd env HOME="$not_a_directory" LC_ALL=C "$INSTALL_SH_UNDER_TEST" --dry-run

	assert_rc 1 'exit 1'
	assert_err 'HOME is not a directory' 'says why'
	assert_err "$not_a_directory" 'names the path it was given'
}
test_case 'a HOME that is not a directory is refused' case_home_not_a_directory

case_diff_missing() {
	setup
	copy_install_script
	managed '.bashrc'
	shim=$(shim_path_without_diff)

	run_cmd env HOME="$HOME_DIR" LC_ALL=C PATH="$shim" \
		"$INSTALL_SH_UNDER_TEST" --dry-run

	assert_rc 1 'exit 1'
	assert_err 'diff not found' 'says which dependency is missing'
	assert_err 'diffutils' 'says what to install'
	assert_not_out 'installed:' 'nothing was reported as installed'
}
test_case 'a missing diff is refused before any work' case_diff_missing

case_no_terminal() {
	setup
	copy_install_script
	managed '.bashrc'
	in_home '.bashrc' 644 'something I wrote'

	run

	assert_rc 1 'exit 1'
	assert_err 'no terminal to ask at' 'says why'
	assert_err '--yes or --keep-existing' 'says what to do about it'
	assert_content '.bashrc' 'something I wrote' 'the drifted file is untouched'
	assert_nothing_outside_home 'nothing outside Home was touched'
}
test_case 'without a terminal it refuses to guess' case_no_terminal

case_dry_run_needs_no_terminal() {
	setup
	copy_install_script
	managed '.bashrc'
	managed '.profile'

	run --dry-run

	assert_rc 0 'exit 0'
	assert_out 'would install: ~/.bashrc' 'reports what it would do'
	assert_nothing_written 'and wrote nothing'
}
test_case '--dry-run needs no terminal' case_dry_run_needs_no_terminal

case_yes_needs_no_terminal() {
	setup
	copy_install_script
	managed '.bashrc'

	run --yes

	assert_rc 0 'exit 0'
	assert_content '.bashrc' '.bashrc' 'the file is installed'
}
test_case '--yes needs no terminal' case_yes_needs_no_terminal

case_keep_existing_needs_no_terminal() {
	setup
	copy_install_script
	managed '.bashrc'

	run --keep-existing

	assert_rc 0 'exit 0'
	assert_content '.bashrc' '.bashrc' 'the file is installed'
}
test_case '--keep-existing needs no terminal' case_keep_existing_needs_no_terminal

run_cases
