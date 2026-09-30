# Copy Managed Files into Home instead of linking them

We copy Managed Files from the Repository into Home rather than symlinking them, and ship
a separate script that reports Drift.

Symlinking would keep a single source of truth and make edits in the Repository instantly
live, which is why the dotfiles world usually reaches for it. It fails badly for one
specific case: plenty of programs append to their own configuration on install — version
managers, language runtimes, SDK bootstrap scripts — and with a symlink that write lands
in the Repository, where it gets committed and pushed. A dotfiles repository is the single
most likely thing on a disk to be pushed somewhere public by accident.

Copying accepts the cost that Home becomes a second, mutable copy of the truth, and pays
for it with a Drift check. Drift is the price of the decision, so it is treated as a
normal state to be inspected on demand rather than a failure to be prevented.
