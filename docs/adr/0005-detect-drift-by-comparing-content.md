# Detect Drift by comparing content against the Repository

`install.sh` decides what to do with each Managed File by comparing its content against the
Repository copy. It keeps no Install Record, consults no timestamps, and has no second
script for reporting differences.

Comparing modification times was the first design, and it does not work. A modification time
records when a file was written, not what it contains, and git rewrites times to the moment
it runs — so `git clone`, `git pull`, and `git checkout` all make Managed Files look freshly
changed. That produces a wall of false warnings on a fresh machine, and worse, a false
all-clear after a `git checkout` of an old branch, precisely when overwriting would be
destructive. Copying the Repository around resets times for reasons unrelated to content, and
a lost executable bit is invisible to time comparison entirely.

An Install Record — a list of what was installed and the hash it had — was the second design.
It buys one thing: distinguishing "both sides were edited to match" from "one side drifted".
No action differs on those two, so the record buys nothing for the cost of a state file to
corrupt, lose, or leave stale. Direct comparison against the Repository covers every case
that matters with a single rule: **a Managed File that already exists in Home and differs
from the Repository is always put to the user before being overwritten.**

Worth stating plainly, because it falls out of the rule rather than being designed in: the
same three cases give a silent, prompt-free full install on a fresh machine, and a prompt for
every difference when this Repository is first adopted on a machine already in use.
