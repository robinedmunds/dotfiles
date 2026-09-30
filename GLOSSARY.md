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
