# Tests for install.sh

```sh
./tests/run.sh                 # everything
./tests/run.sh symlinks drift  # only case files matching these fragments
```

295 assertions in eight files, a few seconds. Plain bash and python3, nothing
else, and no network.

## What it does to your files

Nothing. Every case builds a throwaway sandbox in `/tmp` and points `$HOME`
at a directory inside it:

```
$SANDBOX/repo     a fixture repository: a copy of install.sh plus a home/
$SANDBOX/home     the fake Home, the only thing the script is allowed to write
$SANDBOX/outside  a decoy the script must never touch
$SANDBOX/scratch  the harness's own files
```

`install.sh` works out where the repository is from its own location on disk,
so it is copied into `$SANDBOX/repo` before each run. That is what lets a
case invent a repository of its own. The real `install.sh` in this
repository is never run by a case, and your real `$HOME` is never in scope.

`$SANDBOX/outside` is not decoration. Two cases point a symlink in the fake
Home at it and then assert, by snapshotting the whole sandbox before and
after, that not one byte landed there.

## How the harness avoids fooling itself

**Every invocation closes stdin explicitly.** `install.sh` refuses to run
without a terminal unless told which way to answer, so a test that inherits
your terminal would behave differently from the same test in CI. The harness
never inherits anything.

**Every run pins `LC_ALL=C`.** `install.sh` walks the repository in
`sort` order, so the order of its prompts — and therefore which file a given
answer goes to — is locale-dependent. Pinned, it is deterministic.

**"Wrote nothing" is proven by snapshot, not by grepping output.** A
snapshot records every path under Home with its type, mode, size and
modification time. Comparing before and after catches a rewrite that leaves
identical bytes behind, which checking the log would miss.

**Driver failures fail the case.** If the pty driver dies, the case fails
rather than continuing into assertions that are trivially true because the
captured output is empty.

## Two tiers

Most cases need no terminal: they use `--yes`, `--keep-existing` or
`--dry-run`, all of which run fine with stdin closed.

The prompt cases need a real terminal, because `install.sh` will not prompt
without one. `tests/drive_prompts.py` provides it with `pty.fork()`, which
gives the child a session of its own with the pty as its controlling
terminal. It answers each prompt as it appears, so a script that never
prompts is reported through its exit status rather than waited on forever.

Without python3 those 13 cases **skip**. They are counted and printed, and
`run.sh` still exits 0 — but a green run that skipped half the suite is not
the same as a green run, and the summary says so.

## Layout

| File | Covers |
|---|---|
| `run.sh` | entrypoint: picks case files, totals the results |
| `lib.sh` | sandbox, fixtures, assertions, runner |
| `drive_prompts.py` | pty driver for the prompt cases |
| `cases/preflight.sh` | options, `HOME`, dependencies, the terminal check |
| `cases/repository.sh` | which paths count as Managed Files |
| `cases/fresh.sh` | a machine with nothing installed yet |
| `cases/drift.sh` | files in Home that differ, and each flag's answer |
| `cases/refusals.sh` | everything that makes a file unsafe or impossible |
| `cases/symlinks.sh` | symlinks in both directions (ADR 0004) |
| `cases/dry-run.sh` | the promise that `--dry-run` changes nothing |
| `cases/prompt.sh` | the question itself, and every answer to it |

## Adding a case

```bash
case_overwrites_when_told_to() {
	setup
	copy_install_script
	managed '.bashrc' 644 'export EDITOR=vim'   # in the fixture repository
	in_home '.bashrc' 644 'export EDITOR=emacs' # already in the fake Home

	run --yes

	assert_rc 0 'exit 0'
	assert_content '.bashrc' 'export EDITOR=vim' 'the repository version won'
}
test_case 'the right description, shown in the output' case_overwrites_when_told_to
```

`setup` first, always: it makes a new sandbox, points `$HOME` at it and
freezes the snapshots the "nothing was touched" assertions compare against.

Registering a block inline does not work, and cannot be made to:

```bash
test_case 'nope' { ... }   # bash hands test_case the character { and
                           # parses the body as top-level commands
```

so cases are named functions.

## A suite that can only go green is worthless

Every case here was checked against a deliberately broken `install.sh` to
confirm it fails. Eleven mutations were tried — removing the refusal to write
through a symlinked directory, making `--keep-existing` overwrite, unpruning
nested `.git`, flattening every mode to 644, returning 0 for a partial run,
deleting the terminal check, switching from NUL to newline delimiters,
letting `--dry-run` write, overwriting on end-of-input, not replacing a
symlink destination, and not checking for `diff`. All eleven were caught, and
each by the cases that ought to catch it.

The checker lives outside the repository, in `/tmp/opencode/mutation-check.py`,
because it needs a throwaway copy of the whole repository to work in.

## Known behaviour pinned deliberately

Two cases assert something that looks wrong. Both are commented where they
live. They are pinned so that fixing them cannot pass unnoticed.

- `cases/symlinks.sh` — a symlink under `home/` installs with mode 777,
  because `stat -c %a` without `-L` reports the symlink's own mode. A
  one-word fix in `install.sh`, but not this suite's to make.
- `cases/dry-run.sh` — `--dry-run --yes` exits 2 where `--yes` exits 0, so a
  CI gate written that way reports the machine as never current.
