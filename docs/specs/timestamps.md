# sync-timestamps.sh spec

Replicate one directory's file timestamps onto the matching files in another.

```sh
sync-timestamps.sh [OPTIONS] <dir-a> <dir-b>
```

It exists because copying a tree with `cp`, `rsync`, a backup tool or a git checkout
scrambles modification times, and because the two copies of a tree are then sorted in an
order that has nothing to do with when the files were actually written. Restoring the times
by hand is `find` and `touch`, which is short enough that it gets typed wrongly: the wrong
direction, or `-r` pointed the wrong way round.

## Which directory wins

**DIR_A is the Authoritative Directory.** Every file in DIR_B that has a file at the same
relative path in DIR_A is given DIR_A's modification time. DIR_B's own timestamps are never
the answer; they are only the thing being corrected.

This replaces the earlier version of this script, which took two *files* and gave both of
them the earlier of the two timestamps. "Earlier wins" is a rule about two files with no
correct answer between them; a directory tree has a right answer, and this tool's job is to
find it. DIR_A is named first because it is the one that decides.

There is no flag for the other direction. Swapping the two arguments is the whole of it, and
a flag would let the two disagree with the usage line.

## Pairing

Two files are paired when they have the same path relative to their own directory.

Pairing on content hash or size was rejected. Matching by relative path is what "the same
file in two copies of a tree" means, and it is the only pairing that does not need to read
every file in both directories before changing anything. The cost is stated rather than
hidden: **a file renamed on one side has no Counterpart on the other**, and is reported
rather than paired with whatever now sits at that path.

Symlinks are never followed, in either direction. `find -type f` does not see one in DIR_A, so
it is never read; a symlinked counterpart in DIR_B is reported and skipped, because setting a
timestamp through it would change a file in a third directory that this run was never pointed
at. That is the same rule ADR 0004 draws for `install.sh`, and the same reason.

The awkward case is a path where DIR_A holds a symlink and DIR_B holds a real file. Neither
walk can pair them, because DIR_A's walk never sees the symlink, so nothing would report the
disagreement and the two trees would look covered when they are not. DIR_B's walk reports it:
*"only a symlink at this path in DIR_A"*.

## Depth

One level deep by default, `--recursive` for the whole tree — the same `--recursive` the
`rename-*` tools take, from the same option parser.

A directory's own modification time is not synced. Subdirectory times change as a side effect
of writing files inside them, so syncing them explicitly would be syncing the run's own
footprint.

## Setting the time

`touch -r <dir-a's file> -- <dir-b's file>`. Not `-d @epoch`: `-r` needs no date parsing at
all, which matters on a machine whose `date` cannot read what `stat` prints. That is not
hypothetical — it is the bug that once made `rename-lib.sh` rename files to bare extensions
like `.jpg`, and the reason the shared timestamp readers in `tool-lib.sh` go through
`date -d @<epoch>` instead.

`touch -r` sets the **access** time as well as the modification time. A file in DIR_B is
therefore left with both of the times DIR_A holds for it. This is documented rather than
worked around: undoing it would mean two `touch` calls and a different flag, and a tool that
quietly left atimes behind would sort differently from the tree it claims to mirror.

Comparison is in **whole seconds**, because that is all `stat -c %Y` promises everywhere. A
file that differs only in its sub-second part is reported as already in step and left alone.
Same second, same answer, and re-touching it would claim a change that is not worth making.

The undo log records whole seconds for the same reason: it is the only timestamp that
survives a round trip back through `touch -d`.

## Getting back

`--undo-log FILE` appends one `path<TAB>old_epoch` record per file the run changed — the file
that was changed and the whole seconds it used to carry.

The records are independent, so the log is read **forwards**, unlike the `rename-*` logs which
have to be replayed last-to-first. Each record here sets one file to one timestamp and no
record depends on another, so there is no sequence to get wrong. The run prints its own
reverse command, which is the point: a log you have to read the tool's source to use is not a
way back.

```sh
while IFS=$'\t' read -r path epoch; do touch -d "@$epoch" -- "$path"; done < times.tsv
```

The log is not a rollback. It records where to return to, nothing more: a file changed since
the run, or deleted, is not restored by it.

## Refusals

| Given | Refused because |
|---|---|
| The same directory twice | There is nothing to correct, and the run would read and write one tree. |
| One directory inside the other | With `--recursive` the outer walk descends into the inner one, and every file in it is then looked for at a doubled-up relative path. |
| A file where a directory belongs | It cannot hold files to pair. |
| Not two directories | There is no DIR_A and DIR_B to speak of. |
| `-C` / `--directory` | The two arguments already are the directories. Accepting it and working somewhere else would be worse than refusing it. |
| An empty DIR_A | A mistyped path far more often than a request to do nothing, and "0 changed" reads like success. |

Both paths are normalised with `pwd -P` first, so a trailing slash, a `..` or a symlink cannot
make two arguments look like one directory and slip past the first two checks.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Done. Files may have been skipped; the summary says how many. |
| `1` | Usage error, or nothing matched at the depth asked for. |
| `2` | At least one timestamp could not be set. |

Same numbers as the `rename-*` family, and for the same reason: `sync-timestamps.sh` sources
the same `tool-lib.sh`. It is worth stating that the `img-*` tools use `1` for a runtime
failure and `2` for a usage error, the other way round; that disagreement is recorded in
`tool-lib.sh` and is not reconciled here, because the image tools' behaviour is pinned by
their own spec.

## Behaviour deliberately not included

**No creation and no deletion.** A file in DIR_B with nothing usable at the same path in
DIR_A — no file at all, or only a symlink — is reported and left alone: DIR_B is allowed to
hold more than DIR_A does. A file in DIR_A with nothing to receive it is reported and not
created. Copying is `cp`'s job; this tool changes timestamps and nothing else.

**No directories, no symlinks, no contents.** See Pairing.

**No parallelism.** `find` in a pipeline is sequential, and a run over two thousand files
finishes in well under a second. Parallelising it would add a subshell per file to a loop
whose cost is dominated by two `stat` calls each.

## Relationship to the rest of the family

`sync-timestamps.sh` renames nothing, which is why it does not source `rename-lib.sh`. It
sources `tool-lib.sh` — the option parser, the counters, the summary, the prompt plumbing and
the timestamp readers — which is what makes `--dry-run`, `--interactive`, `--recursive`,
`--undo-log`, `-h` and `-V` behave here exactly as they do in the `rename-*` tools. See
[ADR 0006](../adr/0006-tool-lib-is-the-shared-floor.md) for why the shared part was split out
of `rename-lib.sh` rather than duplicated into a third script.

## To verify before trusting this

Checked on this machine, and each case is in `tests/cases/timestamps.sh`:

- The reverse command above, copied out of the tool's own output and run in a shell, puts
  the old times back.
- `--dry-run` over a tree changes no timestamp at all, proven by snapshotting the whole of
  the sandbox including modification times.
- Running twice changes nothing the second time.
- Ownership, not permission, decides whether a timestamp can be set: the owner of a file can
  touch it whatever its mode says, so a read-only file is not a way to make the tool fail. The
  failure path is reachable only with a file this user does not own, which `/proc/version`
  reliably provides; the case skips elsewhere rather than pretending to have run.