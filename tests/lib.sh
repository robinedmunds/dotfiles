#!/usr/bin/env bash
#
# Test harness for install.sh. See tests/run.sh.
#
# Nothing in here is ever installed: everything outside home/ is tooling
# (ADR 0003).
#
# Every case runs against a throwaway Home inside a throwaway sandbox. The
# script under test is copied into the sandbox so that REPO_ROOT, which it
# derives from its own location, resolves to the fixture rather than to this
# repository. The real Home is never in scope.

# Deliberately no `set -e`: a non-zero exit is the thing under test, and one
# failing case must not silence the rest of the suite.
set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly TESTS_DIR
readonly REPO_ROOT="$TESTS_DIR/.."
readonly INSTALL_SH="$REPO_ROOT/install.sh"

# Counters, reset by setup() and read by run_cases().
PASS=0
FAIL=0
SKIP=0
CASE_FAILURES=0
declare -a CASE_NAMES=()
declare -a CASE_FNS=()
declare -a FAILED_CASES=()
declare -a SKIPPED_CASES=()

# Per-run state, reset by setup().
rc=0
stdout=
stderr=
SANDBOX=
REPO=
HOME_DIR=
SCRATCH=
INSTALL_SH_UNDER_TEST=
OUTSIDE_BEFORE=

# ---------------------------------------------------------------------------
# Case registration
# ---------------------------------------------------------------------------

# test_case DESCRIPTION FUNCTION_NAME
#
# The function is named explicitly rather than passed as a block, because a
# brace group in argument position is not a brace group at all: bash hands
# test_case the literal character and goes on to parse the body as top-level
# commands.
test_case() {
	CASE_NAMES+=("$1")
	CASE_FNS+=("$2")
}

ok() {
	PASS=$((PASS + 1))
	printf '    ok    %s\n' "$*"
}

fail() {
	FAIL=$((FAIL + 1))
	CASE_FAILURES=$((CASE_FAILURES + 1))
	printf '    FAIL  %s\n' "$*"
}

skip() {
	SKIP=$((SKIP + 1))
	printf '    skip  %s\n' "$*"
}

# ---------------------------------------------------------------------------
# Sandbox
# ---------------------------------------------------------------------------

# Builds a sandbox containing:
#
#   $SANDBOX/repo     the fixture repository: a copy of install.sh plus home/
#   $SANDBOX/home     the fake Home the script will write to
#   $SANDBOX/outside  a decoy directory that nothing may ever write to
#   $SANDBOX/scratch  this harness's own files, pruned out of snapshots
# Remove the sandbox, restoring permissions first. A directory the script
# under test has chmod'ed to something without an execute bit -- which is
# exactly what a broken build of install.sh does when it writes through a
# symlink -- cannot be descended into, so a plain rm -rf leaves it behind.
destroy_sandbox() {
	[[ -n ${SANDBOX:-} ]] || return 0
	chmod -R u+rwX -- "$SANDBOX" 2>/dev/null
	rm -rf -- "$SANDBOX"
	SANDBOX=
}

setup() {
	destroy_sandbox

	SANDBOX=$(mktemp -d)
	REPO="$SANDBOX/repo"
	HOME_DIR="$SANDBOX/home"
	SCRATCH="$SANDBOX/scratch"
	INSTALL_SH_UNDER_TEST="$REPO/install.sh"

	mkdir -p "$REPO" "$HOME_DIR" "$SANDBOX/outside" "$SCRATCH"
	export HOME="$HOME_DIR"
	export LC_ALL=C

	trap 'destroy_sandbox' EXIT
}

# The script under test, at its final location in the fixture.
copy_install_script() {
	cp -- "$INSTALL_SH" "$INSTALL_SH_UNDER_TEST"
	chmod +x -- "$INSTALL_SH_UNDER_TEST"
}

# A Managed File in the fixture repository. Defaults: mode 644, content equal
# to the path, which makes a wrong write obvious at a glance.
managed() {
	local rel=$1 mode=${2:-644} content=${3:-}
	[[ -n $content ]] || content=$rel

	mkdir -p -- "$REPO/home/$(dirname -- "$rel")"
	printf '%s\n' "$content" >"$REPO/home/$rel"
	chmod "$mode" -- "$REPO/home/$rel"
}

# A symlink inside the fixture repository's home/, dereferenced on install.
managed_link() {
	local rel=$1 target=$2
	mkdir -p -- "$REPO/home/$(dirname -- "$rel")"
	ln -sfn -- "$target" "$REPO/home/$rel"
}

# A file already present in the fake Home.
in_home() {
	local rel=$1 mode=${2:-644} content=${3:-}
	[[ -n $content ]] || content="existing $rel"

	mkdir -p -- "$HOME_DIR/$(dirname -- "$rel")"
	printf '%s\n' "$content" >"$HOME_DIR/$rel"
	chmod "$mode" -- "$HOME_DIR/$rel"
}

# As managed and in_home, but the content is written byte for byte, with no
# trailing newline added. Needed whenever the newline itself is the thing
# under test.
managed_raw() {
	local rel=$1 mode=${2:-644} content=$3
	mkdir -p -- "$REPO/home/$(dirname -- "$rel")"
	printf '%s' "$content" >"$REPO/home/$rel"
	chmod "$mode" -- "$REPO/home/$rel"
}

in_home_raw() {
	local rel=$1 mode=${2:-644} content=$3
	mkdir -p -- "$HOME_DIR/$(dirname -- "$rel")"
	printf '%s' "$content" >"$HOME_DIR/$rel"
	chmod "$mode" -- "$HOME_DIR/$rel"
}

# Bytes are given as a printf format rather than as a string, because a bash
# string cannot hold a NUL and $'\x00' quietly yields the empty string.
managed_bytes() {
	local rel=$1 mode=$2 format=$3
	mkdir -p -- "$REPO/home/$(dirname -- "$rel")"
	# shellcheck disable=SC2059
	printf "$format" >"$REPO/home/$rel"
	chmod "$mode" -- "$REPO/home/$rel"
}

in_home_bytes() {
	local rel=$1 mode=$2 format=$3
	mkdir -p -- "$HOME_DIR/$(dirname -- "$rel")"
	# shellcheck disable=SC2059
	printf "$format" >"$HOME_DIR/$rel"
	chmod "$mode" -- "$HOME_DIR/$rel"
}

home_link() {
	local rel=$1 target=$2
	mkdir -p -- "$HOME_DIR/$(dirname -- "$rel")"
	ln -sfn -- "$target" "$HOME_DIR/$rel"
}

# ---------------------------------------------------------------------------
# Running the script
# ---------------------------------------------------------------------------

# Run an arbitrary command with stdin closed. A closed stdin is what makes the
# non-interactive paths reachable, and closing it unconditionally is what
# stops a suite run from a developer's terminal behaving differently from one
# run in CI.
run_cmd() {
	stdout=$("$@" </dev/null 2>"$SCRATCH/stderr")
	rc=$?
	stderr=$(cat "$SCRATCH/stderr")
}

# Run the script under test against the fake Home.
run() {
	run_cmd env HOME="$HOME_DIR" LC_ALL=C "$INSTALL_SH_UNDER_TEST" "$@"
}

# True when the prompt-driving pty driver is usable.
have_pty_driver() {
	command -v python3 >/dev/null 2>&1
}

# Drive the script on a pty, answering its prompts.
#
# KEYS holds one answer per prompt, newline separated. A lone EOT character
# sends end-of-input at the prompt instead of an answer.
#
# The child's stdin and stdout are both the pty, which is what install.sh
# insists on before it will ask anything. Everything the child writes, on
# both streams, comes back on stdout; the driver's own complaints go to
# stderr.
pty_run() {
	local keys=$1
	shift

	if ! have_pty_driver; then
		skip 'no python3, so no pty driver and no prompt cases'
		return 1
	fi

	stdout=$(env HOME="$HOME_DIR" LC_ALL=C python3 "$TESTS_DIR/drive_prompts.py" \
		"$keys" -- "$INSTALL_SH_UNDER_TEST" "$@" 2>"$SCRATCH/pty.err")
	rc=$?
	stderr=$(cat "$SCRATCH/pty.err")

	# A driver that fell over leaves stdout empty, which would let the rest of
	# the case pass on assertions that are trivially true. Fail here instead.
	if [[ $stderr == *Traceback* || $stderr == *drive_prompts.py:* ]]; then
		fail "the pty driver failed: $(printf '%s' "$stderr" | tail -1)"
		return 1
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Snapshots
# ---------------------------------------------------------------------------

# Every path under DIR with its type, mode, size and modification time.
# Modification time is included so that a run which rewrites a file with
# identical bytes still shows up as a change.
snapshot() {
	local root=${1:-$HOME_DIR}
	find "$root" -mindepth 1 -printf '%P|%y|%m|%s|%T@\n' 2>/dev/null | sort
}

# The same, for everything in the sandbox that is not the fake Home and not
# this harness's scratch space. Frozen at the end of setup(), so a case can
# prove it wrote nothing outside Home without bookkeeping of its own.
snapshot_outside_home() {
	find "$SANDBOX" -mindepth 1 \
		-path "$HOME_DIR" -prune -o \
		-path "$SCRATCH" -prune -o \
		-printf '%P|%y|%m|%s|%T@\n' 2>/dev/null | sort
}

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

one_line() {
	printf '%s' "$*" | tr '\n' ' '
}

assert_rc() {
	local want=$1 what=$2
	if [[ $rc == "$want" ]]; then
		ok "$what"
	else
		fail "$what -- expected exit $want, got $rc"
		printf '          stdout: %s\n' "$(one_line "$stdout")"
		printf '          stderr: %s\n' "$(one_line "$stderr")"
	fi
}

assert_out() {
	local want=$1 what=$2
	if [[ $stdout == *"$want"* ]]; then
		ok "$what"
	else
		fail "$what -- stdout does not contain: $want"
		printf '          stdout: %s\n' "$(one_line "$stdout")"
	fi
}

assert_not_out() {
	local unwanted=$1 what=$2
	if [[ $stdout != *"$unwanted"* ]]; then
		ok "$what"
	else
		fail "$what -- stdout unexpectedly contains: $unwanted"
		printf '          stdout: %s\n' "$(one_line "$stdout")"
	fi
}

assert_err() {
	local want=$1 what=$2
	if [[ $stderr == *"$want"* ]]; then
		ok "$what"
	else
		fail "$what -- stderr does not contain: $want"
		printf '          stderr: %s\n' "$(one_line "$stderr")"
	fi
}

assert_not_err() {
	local unwanted=$1 what=$2
	if [[ $stderr != *"$unwanted"* ]]; then
		ok "$what"
	else
		fail "$what -- stderr unexpectedly contains: $unwanted"
		printf '          stderr: %s\n' "$(one_line "$stderr")"
	fi
}

# The Managed File at REL holds exactly TEXT.
assert_content() {
	local rel=$1 want=$2 what=$3
	local got
	if [[ ! -e $HOME_DIR/$rel && ! -L $HOME_DIR/$rel ]]; then
		fail "$what -- ~/rel missing: $rel"
		return
	fi
	got=$(cat -- "$HOME_DIR/$rel" 2>/dev/null)
	if [[ $got == "$want" ]]; then
		ok "$what"
	else
		fail "$what -- ~/$rel is '$got', expected '$want'"
	fi
}

# Nothing exists at REL, and it is not a dangling symlink either.
# As assert_content, for a path outside Home.
assert_content_for() {
	local path=$1 want=$2 what=$3
	local got
	if [[ ! -e $path ]]; then
		fail "$what -- $path is missing"
		return
	fi
	got=$(cat -- "$path")
	if [[ $got == "$want" ]]; then
		ok "$what"
	else
		fail "$what -- $path is '$got', expected '$want'"
	fi
}

# The Managed File at REL holds exactly the bytes described by the printf
# format FORMAT. For content a bash string cannot carry.
assert_matches() {
	local rel=$1 format=$2 what=$3
	if [[ ! -e $HOME_DIR/$rel ]]; then
		fail "$what -- ~/$rel is missing"
		return
	fi
	# shellcheck disable=SC2059
	if printf "$format" | cmp -s - "$HOME_DIR/$rel"; then
		ok "$what"
	else
		fail "$what -- ~/$rel does not have the expected bytes"
	fi
}

assert_absent() {
	local rel=$1 what=$2
	if [[ -e $HOME_DIR/$rel || -L $HOME_DIR/$rel ]]; then
		fail "$what -- ~/$rel exists but should not"
		return
	fi
	ok "$what"
}

assert_mode() {
	local rel=$1 want=$2 what=$3
	local got
	if [[ ! -e $HOME_DIR/$rel ]]; then
		fail "$what -- ~/$rel is missing"
		return
	fi
	got=$(stat -c '%a' -- "$HOME_DIR/$rel")
	if [[ $got == "$want" ]]; then
		ok "$what"
	else
		fail "$what -- ~/$rel is mode $got, expected $want"
	fi
}

assert_regular_file() {
	local rel=$1 what=$2
	if [[ -f $HOME_DIR/$rel && ! -L $HOME_DIR/$rel ]]; then
		ok "$what"
	else
		fail "$what -- ~/$rel is not a regular file"
	fi
}

assert_symlink() {
	local rel=$1 what=$2
	if [[ -L $HOME_DIR/$rel ]]; then
		ok "$what"
	else
		fail "$what -- ~/$rel is not a symlink"
	fi
}

assert_exists() {
	local rel=$1 what=$2
	if [[ -e $HOME_DIR/$rel ]]; then
		ok "$what"
	else
		fail "$what -- ~/$rel does not exist"
	fi
}

# HOME is byte-for-byte what it was when setup() finished.
assert_nothing_written() {
	local what=$1
	if [[ $(snapshot) == "$HOME_BEFORE" ]]; then
		ok "$what"
	else
		fail "$what -- Home changed"
		diff <(printf '%s\n' "$HOME_BEFORE") <(snapshot) | sed 's/^/          /' >&2
	fi
}

# Nothing outside Home changed. Caught by setup(), frozen before any run.
assert_nothing_outside_home() {
	local what=$1
	local now
	now=$(snapshot_outside_home)
	if [[ $now == "$OUTSIDE_BEFORE" ]]; then
		ok "$what"
	else
		fail "$what -- something outside Home changed"
		diff <(printf '%s\n' "$OUTSIDE_BEFORE") <(now) | sed 's/^/          /' >&2
	fi
}

# FIRST appears before SECOND in the captured output.
assert_before() {
	local first=$1 second=$2 what=$3
	local f s
	f=$(printf '%s\n' "$stdout" | grep -n -F -m1 -e "$first" | cut -d: -f1)
	s=$(printf '%s\n' "$stdout" | grep -n -F -m1 -e "$second" | cut -d: -f1)
	if [[ -n $f && -n $s && $f -lt $s ]]; then
		ok "$what"
	else
		fail "$what -- '$first' at line ${f:-none}, '$second' at line ${s:-none}"
	fi
}

# stdout contains exactly COUNT lines matching PATTERN.
assert_count() {
	local pattern=$1 want=$2 what=$3
	local got
	got=$(printf '%s\n' "$stdout" | grep -c -F -e "$pattern")
	if [[ $got == "$want" ]]; then
		ok "$what"
	else
		fail "$what -- '$pattern' appears $got times, expected $want"
		printf '          stdout: %s\n' "$(one_line "$stdout")"
	fi
}

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

run_cases() {
	local i name
	for ((i = 0; i < ${#CASE_NAMES[@]}; i++)); do
		name=${CASE_NAMES[i]}
		CASE_FAILURES=0
		printf '  %s\n' "$name"
		HOME_BEFORE=
		"${CASE_FNS[i]}"
		if ((CASE_FAILURES > 0)); then FAILED_CASES+=("$name"); fi
	done

	printf 'SUMMARY pass=%d fail=%d skip=%d\n' "$PASS" "$FAIL" "$SKIP"
	if ((${#FAILED_CASES[@]} > 0)); then
		printf 'failing cases:\n'
		printf '  - %s\n' "${FAILED_CASES[@]}"
	fi
	((FAIL == 0))
}
