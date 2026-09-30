# Symlinks in Home are replaced, never written through

When a path in Home is a symlink and the Repository supplies a regular file for that path,
`install.sh` replaces the symlink with a regular file. It never writes through a symlink, and
it refuses to install into a symlinked directory.

The tempting behaviour is to follow the link and write the target, on the reasoning that
someone who made the link presumably wanted their file written. It is unsafe here for two
reasons. The first is scope: a symlink can point anywhere, so a `~/.bashrc` that links into
`/etc` would turn a tool that needs no privileges into one that writes system configuration,
breaking the boundary ADR 0002 draws. The second is surprise: the write lands somewhere the
user is not looking, and the script reports success.

Symlinked directories are refused rather than traversed for the same reason. `~/.config/nvim`
being a link to a checkout somewhere else means installing one Managed File silently writes
outside Home — the exact situation this repository does not manage.

The consequence is that symlink-based sharing between two configuration locations does not
survive an Install. Copying resolved content means both locations end up as independent real
files, which is a deliberate trade of shared editing for predictability.
