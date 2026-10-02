# Arch Desktop Dotfiles

A git-tracked collection of one person's configuration files and helper scripts for an
Arch Linux desktop, together with the tooling that copies them into a home directory
and reports where that home directory has stopped matching the repository.

## Language

**Repository**:
The git-tracked source tree holding the desired state of every Managed File, plus the
tooling that acts on them.
_Avoid_: dotfiles folder, source, repo

**Home**:
The user's home directory, holding the live copies that the desktop actually reads.
Home is writable by hand and by the applications it runs.
_Avoid_: target, destination, `~`

**Managed File**:
A file whose desired contents live in the Repository and whose live copy lives in Home.
The Repository owns it, and an Install may overwrite it.
_Avoid_: tracked file, owned file, dotfile

**Unmanaged File**:
A file present in Home with no counterpart in the Repository. No tooling here ever
reads, writes, or removes one.
_Avoid_: local override, extra file, orphan

**Install**:
The act of copying Managed Files from the Repository into Home. A Managed File that already
exists in Home and differs from the Repository is put to the user before being replaced.
_Avoid_: deploy, apply, sync, provision, restore

**Drift**:
The state in which a Managed File's copy in Home no longer matches its counterpart in
the Repository. Drift is an expected steady state, not an error condition.
_Avoid_: diff, conflict, divergence

**Secret**:
Sensitive material — private keys, tokens, passwords — that is never committed to the
Repository and never Managed. Secrets exist only in Home, untouched by this tooling.
_Avoid_: credentials, sensitive file

## Tools

**Authoritative Directory**:
Of two directories holding copies of the same files, the one whose timestamps are taken as
the correct ones. Every other file in the other directory is corrected to match it, and files
present only in the other directory are left alone.
_Avoid_: master, original, primary, left, A

**Counterpart**:
The file in the other directory that has the same path relative to its own directory's root.
Two files are a pair of Counterparts when their relative paths match, which is what "the same
file in two copies of a tree" means. Pairing on relative path rather than content is
deliberate, so a file renamed on one side has no Counterpart on the other and is reported
rather than paired with whatever now sits at that path.
_Avoid_: match, twin, same file, original

**Undo Log**:
An append-only file recording one line per change a tool made, in enough detail to put things
back: the path and what it was called before. It records where to return to, nothing more.
It is never a rollback — a file changed or deleted since the run is not restored by replaying
the log — and it lives outside every directory the tool was pointed at, because it is an
ordinary file that a tool working through a directory will otherwise find and change.
_Avoid_: backup, history, journal, manifest
