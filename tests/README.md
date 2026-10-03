# Tests for the scripts

```sh
./tests/run.sh                 # everything
./tests/run.sh symlinks drift  # only case files matching these fragments
```

Eight files cover `install.sh`. Two cover the tools in `home/.local/bin` — described under
[The tool cases](#the-tool-cases) below, because they reach the scripts a different way.

429 assertions in ten files, a few seconds. Plain bash and python3, no network.
It also leans on `find -print0`, `sort -z`, `stat -c` and `date` -- all present in
GNU coreutils/findutils and in BusyBox, which is the whole of what it asks for.

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

**The snapshot has to be able to fail.** An earlier version built the snapshot
with `find -printf`, a GNU extension. On BusyBox that `find` prints its usage to
stderr and emits nothing, and an empty snapshot compares equal to an empty
baseline -- so every "wrote nothing" assertion passed without looking at
anything. The suite reported 295 green assertions while testing none of that.
Two things guard against it now: the snapshot is built from `find -print0` plus
`stat`, which BusyBox has, and `run_cases` refuses to start until it has seen
the machinery produce a real line for a known file.

**Modification time has to be precise enough to mean something.** Only whole
seconds are available where `stat` cannot report fractional ones, and a rewrite
landing in the same second as the write before it is then invisible. Before any
second or later run, `freeze_snapshots` waits for the second to turn over, so
that this run's writes are strictly newer than the previous run's. First runs
skip the wait: a single run only writes where the content differs or the file is
missing, so it cannot produce a change only the modification time would reveal.

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

## The tool cases

`cases/timestamps.sh` covers `sync-timestamps.sh`, and there are three differences worth
knowing before adding to it.

**It runs the script out of the Repository, not from an installed copy.** The real
`~/.local/bin/sync-timestamps.sh` on this machine is never what a case tests; the one in
`home/.local/bin` is, so a case cannot pass against a stale install. This works because each
tool resolves its library relative to its own location rather than through `PATH`, which is a
property worth having and worth testing.

**The fixtures are directories inside the fake Home.** `$HOME/a` and `$HOME/b`, with the
working directory set to the fake Home so a case can say `a b`. That reuses the existing
snapshot machinery whole: the "wrote nothing" assertion is the same one `install.sh` uses, and
because the snapshot carries modification times it catches a timestamp change that leaves the
bytes identical — which for this tool is *the* way to fail.

**The interactive cases need no terminal.** `sync-timestamps.sh` asks its questions on fd 3,
which is a copy of the stdin it was started with, and walks its file list down a pipe of its own
making. A pipe on stdin is therefore answers and not filenames, so `run_tool_with_input` can
drive it without python3 and without a skip. `run_tool` closes stdin by default for the same
reason `run` does: a prompt left to inherit the terminal running the suite would take its
answer from wherever the suite happened to be run from.

One case reaches outside the sandbox on purpose. Setting a timestamp is refused by ownership
rather than by mode — the owner of a file can `touch` it whatever its mode says — so a
read-only file is not a way to make the tool fail, and the failure path is unreachable in a
sandbox this user owns. `/proc/version` is the one file reliably present that this user does
not own and cannot write. The case probes that first and **skips** rather than pretending to
have run, in keeping with the rule above.

`cases/image.sh` covers `img-resize.sh` and the three fixed-size wrappers, and one thing
about it is worth knowing before adding to it.

**libvips is stood in for, not installed.** What these tools do is decide what to ask
libvips for — which orientation, which two target dimensions, whether to rotate — and that
decision is worth testing precisely because it does not need libvips to be there. So each
case builds a directory of stand-ins for `vips`, `vipsheader` and `exiftool`, puts it at the
front of `PATH`, and puts `PATH` back at the end of the case. A case that leaked that
directory would make every case after it test a fake, which is why the three are named
explicitly rather than discovered: a case proving something is *not* consulted has to
guarantee the thing it is proving the absence of was findable.

**The stand-ins write down every call.** The fixtures are not real images, so each one
carries a facts file beside it saying what a reader should say about it — including, for
the cases that model a broken build, that a reader should say nothing. Because every call is
recorded, "a screenshot is resized without a reader being consulted" is an assertion about
calls that did not happen, which is the only way to test the fix that made screenshots work.

Every decision in the orientation path is mutation-checked, with the checker at
`/tmp/opencode/mutation-check-image.py`. Twelve mutations, all caught, and each by the case
aimed at it rather than by whichever assertion happened to be standing nearby — the checker
asserts the *expected* case failed, so a mutation caught by accident shows up as one caught
for the wrong reason, and one of these was: a broken Exif search is caught by the refusal
case, because a file whose Exif cannot be read would then be assumed upright.

One of the twelve is there because it caught a real bug rather than a hypothetical one.
`il_orientation` returns how the orientation was settled along with the value, in one
string, and the caller splits it — which is only necessary because the read happens in
`ORIENTATION=$(...)`, so a variable the library set would be set in the subshell and lost.
The first version returned it as a variable, and the resize still came out upright for every
case in the suite: there was no tag to apply in the first place, so losing the kind changed
nothing visible except that `--no-rotate` went missing. A mutation that removes the printing
of the kind fails one assertion.

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
| `cases/timestamps.sh` | `sync-timestamps.sh`, run out of the Repository |
| `cases/image.sh` | `img-resize.sh` and the three fixed-size wrappers |

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

`setup` first, always: it makes a new sandbox and points `$HOME` at it. The
snapshots the "nothing was touched" assertions compare against are frozen by
`run`, not by `setup`, because a case builds its fixtures *after* `setup`
returns — `copy_install_script` writes into the fixture repository, `in_home`
writes into Home itself, and a case may create a decoy under `$SANDBOX/outside`
before the run. A baseline taken any earlier would count the fixture as the
thing that changed.

A case for a script in `home/.local/bin` uses `run_tool` in place of `run`, with the script's
name and its own arguments:

```bash
run_tool sync-timestamps.sh --dry-run a b

assert_rc 0 'exit 0'
assert_same_mtime 'a/f.txt' 'b/f.txt' 'DIR_B took the time from DIR_A'
```

`run_tool` freezes the same snapshots `run` does, so `assert_nothing_written` works in a tool
case unchanged. `assert_mtime REL WHAT` takes any date `touch -d` accepts rather than an epoch,
because a case with `1659946088` hard-coded in it cannot be read.

Registering a block inline does not work, and cannot be made to:

```bash
test_case 'nope' { ... }   # bash hands test_case the character { and
                           # parses the body as top-level commands
```

so cases are named functions.

## A suite that can only go green is worthless

Every case here was checked against a deliberately broken `install.sh` to
confirm it fails. Twelve mutations were tried — removing the refusal to write
through a symlinked directory, making `--keep-existing` overwrite, unpruning
nested `.git`, flattening every mode to 644, returning 0 for a partial run,
deleting the terminal check, letting `--dry-run` write, overwriting on
end-of-input, not replacing a symlink destination, not checking for `diff`,
rewriting every file on every run, and breaking the harness's own snapshot so it
returns nothing. All twelve were caught, and each by the cases that ought to
catch it.

That last one is the one worth dwelling on. The other eleven are bugs in
`install.sh`; the twelfth breaks the measurement rather than the thing measured,
and it was caught by `snapshot_self_check` refusing to run — which is the only
reason it is worth having. Before that check existed, that mutation produced a
fully green run of all 295 assertions, on a machine whose `find` had no
`-printf`, testing nothing at all.

The checker lives outside the repository, in `/tmp/opencode/mutation-check.py`,
because it needs a throwaway copy of the whole repository to work in.

`cases/timestamps.sh` was checked the same way, against nineteen mutations of
`sync-timestamps.sh` and `tool-lib.sh` — all nineteen caught. Two candidates were dropped
before running, and why is the useful part: mutating `rename-lib.sh` proves nothing about
these cases, because `sync-timestamps.sh` does not source it, and removing the double-source
guard in `tool-lib.sh` introduces no bug, since everything it re-runs is an idempotent
assignment. A mutation that cannot express a bug is not evidence of a hole. The rest were
aimed at the ways this tool could plausibly be wrong — the direction reversed, `--dry-run`
writing, the same-directory and nesting refusals deleted, a file with no Counterpart written
anyway, a symlink written through, a file in DIR_B whose counterpart in DIR_A is only a
symlink going unreported, an empty DIR_A reported as a clean run, the depth fixed at one, the
Undo Log recording nothing, the printed reverse command doing nothing, `--interactive`
ignored, a failure not counted, a DIR_B-only file unreported, the summary counting renames,
and the shared parser accepting an unknown flag, deferring an unwritable Undo Log to
mid-run, dropping the failed exit code and scanning only the first argument for help.

Writing those mutations found a gap the cases had not: nothing anywhere tested the shared
parser's unknown-flag or unwritable-log paths, because the `rename-*` tools have no coverage
at all. Two cases were added for them before the checker was run.

Its checker is at `/tmp/opencode/mutation-check-timestamps.py`, alongside the other.

`cases/image.sh` is checked the same way, against twelve mutations of `image-lib.sh` and
`img-resize.sh` — the dead Exif hatch restored, a format that keeps its rotation outside
Exif taken on trust, a reader's answer believed whatever it is, the exiftool fallback
deleted, the Exif byte search searching for nothing, an assumed orientation left for libvips
to rotate on its own, the kind returned in a variable rather than in the string it is read
through, the 90 degree swap dropped, `--assume-upright` accepted and ignored, the doctor
probing a JPEG twice and never a PNG, and the way out of a refusal deleted from the doctor
and from the help. All twelve caught. Two candidates were dropped before running, and why is
the useful part: mutating `img-convert.sh` proves nothing about these cases, because nothing
here runs it, and breaking the stand-ins themselves proves nothing about the tools under
test, because a case would fail for a reason that has nothing to do with the decision it
exists to check.

## Known behaviour pinned deliberately

Three cases assert something that looks wrong. All are commented where they
live. They are pinned so that fixing them cannot pass unnoticed.

- `cases/symlinks.sh` — a symlink under `home/` installs with mode 777,
  because `stat -c %a` without `-L` reports the symlink's own mode. A
  one-word fix in `install.sh`, but not this suite's to make.
- `cases/dry-run.sh` — `--dry-run --yes` exits 2 where `--yes` exits 0, so a
  CI gate written that way reports the machine as never current.
- `cases/timestamps.sh` — `touch -r` sets the access time as well as the
  modification time, so a file in DIR_B ends up with DIR_A's atime too. A
  documented property of the tool, not an oversight; see
  [docs/specs/timestamps.md](../docs/specs/timestamps.md).
