# Installers touch files only — no packages, no root

The tooling copies and compares files. It never installs packages, reaches the network, or
requires `sudo`.

The tempting alternative is one script that also runs `pacman -S`, enables systemd units,
and installs an AUR helper, taking a bare Arch machine all the way to a working desktop in
one command. That script needs root, needs the network, is hard to make safely repeatable,
and puts the desktop one typo away from being broken. It also cannot be pointed at a
throwaway `HOME` to check what it does before letting it near a real machine.

The tooling does depend on packages being present — `diffutils`, so that a difference can be
shown at the point where a decision is made — but it declares that dependency rather than
satisfying it. `install.sh` checks for what it needs at startup and refuses to continue if
something is missing, reporting which dependency is absent. It does not offer to install it.
Declaring a dependency is not provisioning one: the script still installs nothing, still
reaches no network, and the rule that it never needs root still holds.

Restoring a machine's packages and restoring its files are separate concerns with
different failure modes and different blast radii, so they get separate tools. If package
provisioning is ever wanted, it goes in its own script that this repository does not own.

The explicit no's: this repository does not manage system state, does not know what
packages exist, and does not attempt to describe what a machine "should" have installed.

The boundary is drawn at the directory, not at the topic: this repository writes only inside
Home. Configuration the OS reads from `/etc` — `/etc/hostname`, `/etc/locale.conf`,
`/etc/systemd/logind.conf.d/`, `/etc/lightdm/`, `/etc/fstab`, kernel command lines — is out
of scope even when it is plainly about the desktop, because writing it requires root.
Settings that merely *feel* system-wide but are read from Home by a desktop program, such as
display names, resolutions and refresh rates in a compositor config, are in scope: those are
ordinary Managed Files. This repository assumes a single machine and expects its Managed
Files to be safe anywhere bash runs; per-machine variation is out of scope until it is
actually needed.
