# tool-lib.sh is the shared floor; rename-lib.sh is what is left of the renaming

`~/.local/bin` scripts that share an interface source `tool-lib.sh` for it: the option
parser, the counters, the diagnostics, the summary line, the prompt plumbing and the timestamp
readers. `rename-lib.sh` sources `tool-lib.sh` and adds only what is about renaming — the
rename primitive, the free-name search, name splitting, the UUID generator and the rename log's
reverse command. `sync-timestamps.sh` sources `tool-lib.sh` and `rename-lib.sh` not at all.

The alternative was a third copy of the parser in `sync-timestamps.sh`. The reason not to is
the one `rename-lib.sh`'s own header has always claimed for itself: *"One option parser and one
help block, so the four tools cannot drift apart in which flags they accept or how they
describe them."* That argument does not stop being true because a fifth tool has appeared; it
gets stronger, because the ways to drift are now two copies of each shared decision rather than
one. A sixth tool would have made the split worth doing on its own, but `sync-timestamps.sh` is
the fifth and the one that has nothing to rename.

The split is one file, not a package. `tool-lib.sh` and `rename-lib.sh` are both resolved by
each tool relative to its own location, so nothing needs installing and nothing needs to know
what else is in the directory. `rename-lib.sh` resolves `tool-lib.sh` from its own path rather
than from `$0`, because a tool reaches it through a path of its own and the two do not have to
agree.

Two consequences of the split are worth naming, since neither is free:

**The shared `--undo-log` description no longer describes a record format.** It used to say the
log held one `old<TAB>new` line per rename, which was true for all four tools and would have
been a lie for a tool that renames nothing. It now describes appending and reversing, and each
tool states its own format through a shared `to_undo_log_note` helper — so the wording of that
one sentence is still written once. The four `rename-*` tools' `--help` output changes by these
few lines. That is deliberate, and it is the only user-visible change to them.

**`to_summary` takes the verbs as arguments.** It defaulted to `renamed` / `to rename` rather
than being asked for them, because that default is what keeps the four rename tools' output
byte-identical. A library whose shared function is worded for its loudest member is a library
that will eventually be wrong for the others; this one has the words as parameters and a default
that happens to be right for the family that exists.

`image-lib.sh` was left alone. It is a second family with its own conventions, and its exit
codes are inverted relative to this one — `1` for a runtime failure, `2` for a usage error,
where `tool-lib.sh` keeps the `rename-*` family's `1` for usage and `2` for failure. Reconciling
that is separate work, and the image tools' behaviour is pinned by their spec, so it should not
be swept into a refactor.

## Alternatives

**Leave `rename-lib.sh` whole and add `timestamps-lib.sh` that sources it.** Then
`sync-timestamps.sh` inherits the rename machinery it does not use, and its readers cannot tell
which half of a sourced library is theirs.

**A single `lib.sh` for everything under `~/.local/bin`.** It would hold the image tools'
backend detection and format tables alongside the rename tools' name splitting, and would grow a
dependency every script in the directory shares. The two families have nothing to say to each
other; the shared floor they do share is the small part, and that part is what was extracted.

**Duplicating the parser.** Rejected for the reason above, and it is also how the BusyBox
timestamp bug got as far as it did: the `date -d "$(stat -c %y)"` fix was made once, in one
place, and nobody had to find the other four.