# Managed Files live under `home/`, mirroring Home

The Repository has two trees. `home/` mirrors Home exactly, so `home/.config/nvim/init.lua`
installs to `$HOME/.config/nvim/init.lua`. Everything else in the Repository is tooling and
documentation, and is never installed.

The obvious alternative is to let the Repository root mirror Home, so `.bashrc` sits at the
top level and lands at `~/.bashrc`. That is tidier to type, and it is what most dotfiles
directories look like. It fails because the Repository root then holds two different kinds
of thing: Managed Files, and the machinery that installs them. Nothing in the path tells
them apart, so the tooling needs a hand-maintained exclusion list — and a Repository file
somebody forgot to exclude gets copied into Home as though the user had meant to put it
there. `home/` makes the distinction structural rather than remembered.

A manifest mapping source paths to destination paths was rejected as the third option: it
costs the most to maintain, and the one rule it replaces — "the path is the destination" —
is already carried by the directory name.
