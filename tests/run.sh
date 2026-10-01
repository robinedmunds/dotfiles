#!/usr/bin/env bash
#
# Run the install.sh test suite.
#
#   ./tests/run.sh              run every case file
#   ./tests/run.sh symlinks     run only case files matching a name fragment
#
# Nothing here touches your real Home. Every case gets a throwaway one.

set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

if [[ ! -f $TESTS_DIR/lib.sh ]]; then
	printf 'missing %s\n' "$TESTS_DIR/lib.sh" >&2
	exit 1
fi
if [[ ! -f $TESTS_DIR/../install.sh ]]; then
	printf 'this suite must live inside the repository it tests\n' >&2
	exit 1
fi

shopt -s nullglob
files=("$TESTS_DIR"/cases/*.sh)
shopt -u nullglob

if ((${#files[@]} == 0)); then
	printf 'no case files in %s/cases\n' "$TESTS_DIR" >&2
	exit 1
fi

selected=()
if (($# == 0)); then
	selected=("${files[@]}")
else
	for file in "${files[@]}"; do
		for pattern in "$@"; do
			if [[ ${file##*/} == *"$pattern"* ]]; then
				selected+=("$file")
				break
			fi
		done
	done
fi

if ((${#selected[@]} == 0)); then
	printf 'no case files matched: %s\n' "$*" >&2
	exit 1
fi

total_pass=0
total_fail=0
total_skip=0
declare -a broken_files=()

for file in "${selected[@]}"; do
	name=${file##*/}
	printf '\n%s\n' "$name"

	output=$(bash "$file")
	status=$?
	printf '%s\n' "$output"

	summary=$(printf '%s\n' "$output" | grep -m1 '^SUMMARY ')
	if [[ $summary =~ pass=([0-9]+)\ fail=([0-9]+)\ skip=([0-9]+) ]]; then
		total_pass=$((total_pass + BASH_REMATCH[1]))
		total_fail=$((total_fail + BASH_REMATCH[2]))
		total_skip=$((total_skip + BASH_REMATCH[3]))
	fi
	((status == 0)) || broken_files+=("$name")
done

printf '\n%d files, %d passed, %d failed, %d skipped\n' \
	"${#selected[@]}" "$total_pass" "$total_fail" "$total_skip"

if ((${#broken_files[@]} > 0)); then
	printf 'failing files:\n'
	printf '  - %s\n' "${broken_files[@]}"
	exit 1
fi

if ((total_skip > 0)); then
	printf 'note: skipped cases are not passing cases\n'
fi
exit 0
