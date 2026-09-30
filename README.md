# dotfiles

My configuration files and scripts for an Arch Linux desktop, plus the one script
that installs them.

## How this works

Configuration lives in `home/`, and mirrors the paths it occupies in my home
directory. A file at `home/<path>` installs to `$HOME/<path>`:

```
home/.bashrc                ->  ~/.bashrc
home/.config/nvim/init.lua  ->  ~/.config/nvim/init.lua
home/.local/bin/something   ->  ~/.local/bin/something
```

Everything outside `home/` is tooling. It is never installed.

**The repository is the source of truth. Do not edit files in your home
directory — edit them here and run `./install.sh`.** If you do edit in your home
directory, `install.sh` will offer to overwrite your changes on the next run.

Run it from anywhere; it works out where the repository is on its own:

```sh
./install.sh --dry-run    # see everything, change nothing
./install.sh              # install, asking before overwriting anything
```

## If you are adopting this on a machine you already use

Your existing configuration differs from what is in here, so you will be asked
about every file that exists and differs. **Look at the diff before you answer.**

Enter means overwrite, and it is the default. That is a deliberate choice and it
is a real risk: hold Enter down on a first run and you will overwrite a
configuration you spent time on, with the script reporting success.

`--dry-run` first is the cheap way to avoid it. Nothing is faster than the
afternoon you would otherwise lose.

## Options

| Flag | Effect |
|---|---|
| `--dry-run` | Report everything that would happen. Writes nothing, asks nothing. |
| `--yes` | Overwrite every drifted file without asking. Required without a terminal. |
| `--keep-existing` | Install only what is missing, change nothing else. Required without a terminal. |
| `-h`, `--help` | Usage. |

One of `--yes` / `--keep-existing` is required when there is no terminal to ask
at. It will not guess which way you would have answered. `--dry-run` never asks,
so it works without a terminal — that is what makes it usable from a script.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Every Managed File is in sync afterwards. |
| `1` | Usage error, missing dependency, or a file was refused. |
| `2` | Finished, but `$HOME` is not fully in sync — something was kept, or you quit early. |

So `install.sh; echo $?` tells you whether this machine is current.

## Dependencies

`bash` and `diffutils` (for `diff`). Nothing else, no network, no `sudo`.

`install.sh` checks for these at startup and stops with a message if one is
missing. It will not install them for you — see
[ADR 0002](docs/adr/0002-installers-touch-files-only.md).

## What it will not do

- Install packages, enable services, or touch the network
- Write anything outside `$HOME` — `/etc` and everything in it is out of scope
- Follow a symlink. If a destination is a symlink it is replaced with a regular
  file; if a destination *directory* is a symlink, that file is refused.
- Delete anything from `$HOME`
- Stop to ask about a file whose contents are already identical. If only the
  executable bit differs it is fixed silently, because the bytes are the same.
- Install a nested `.git` directory. Nothing else is excluded.

## Guarding against committed secrets

`pre-commit` scans staged content for private keys, AWS and GitHub tokens, and
credential-shaped assignments. It is plain bash and `grep`, and runs locally.

```sh
git config core.hooksPath .githooks
```

`.githooks/` is a normal tracked directory, so the hook is present and working
after a fresh clone. Bypass a false positive with `git commit --no-verify`.

## Documentation

- [GLOSSARY.md](GLOSSARY.md) — the vocabulary this project uses
- [docs/adr/](docs/adr/) — why things work the way they do

| ADR | Decision |
|---|---|
| [0001](docs/adr/0001-copy-managed-files-into-home-instead-of-linking-them.md) | Copy Managed Files into Home instead of linking them |
| [0002](docs/adr/0002-installers-touch-files-only.md) | Installers touch files only — no packages, no root |
| [0003](docs/adr/0003-managed-files-live-under-home.md) | Managed Files live under `home/`, mirroring Home |
| [0004](docs/adr/0004-symlinks-in-home-are-replaced-never-written-through.md) | Symlinks in Home are replaced, never written through |
| [0005](docs/adr/0005-detect-drift-by-comparing-content.md) | Detect Drift by comparing content against the repository |

## Assumptions

One machine. Managed Files are expected to be safe anywhere bash runs. If
per-machine variation turns out to be needed, it will be added when it is
actually needed.
