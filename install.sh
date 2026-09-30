#!/usr/bin/env bash
#
# Install Managed Files from home/ into $HOME.
#
# A Managed File at home/<path> is installed to $HOME/<path>. Everything outside
# home/ in this repository is tooling and is never installed.
#
# See GLOSSARY.md for the vocabulary and docs/adr/ for why it works this way.
# In short: compare content, ask before overwriting, never write outside Home,
# never need root, never touch the network.

set -euo pipefail

readonly PROGNAME="${0##*/}"

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REPO_ROOT
readonly SRC_DIR="$REPO_ROOT/home"
readonly DEST="${HOME:-}"

# Flags
dry_run=0
assume_yes=0
keep_existing=0

# Counters
installed=0
in_sync=0
overwritten=0
kept=0
refused=0
mode_fixed=0
quit_early=0
would_change=0

usage() {
	cat <<EOF
Usage: $PROGNAME [options]

Copies Managed Files from home/ into \$HOME, asking before replacing any file
that already exists and differs from the repository.

Options:
  --dry-run          Report everything that would happen. Writes nothing,
                     asks nothing, changes nothing.
  --yes              Overwrite every drifted file without asking. Required when
                     there is no terminal to ask at.
  --keep-existing    Keep every existing file, install only what is missing.
                     Required when there is no terminal to ask at.
  -h, --help         Show this help.

Exit codes:
  0  every Managed File is in sync with the repository afterwards
  1  usage error, missing dependency, or a file was refused
  2  finished, but \$HOME is not fully in sync (something was kept, or you quit)
EOF
}

log() { printf '[%s] %s\n' "$PROGNAME" "$*"; }
warn() { printf '[%s] warning: %s\n' "$PROGNAME" "$*" >&2; }
die() {
	printf '[%s] error: %s\n' "$PROGNAME" "$*" >&2
	exit 1
}

# Report a problem that makes $HOME impossible to reason about, but keep going
# so the user sees the full picture in one run.
refuse() {
	warn "$1"
	refused=$((refused + 1))
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

while (($# > 0)); do
	case $1 in
	--dry-run)
		dry_run=1
		;;
	--yes)
		assume_yes=1
		;;
	--keep-existing)
		keep_existing=1
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		usage >&2
		die "unknown option: $1"
		;;
	esac
	shift
done

if ((assume_yes && keep_existing)); then
	usage >&2
	die "--yes and --keep-existing contradict each other"
fi

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

[[ -n $DEST ]] || die 'HOME is not set'
[[ -d $DEST ]] || die "HOME is not a directory: $DEST"

# The prompt is only worth having if it can show what changed. Degrading to a
# bare path would quietly remove the one thing that informs the decision.
command -v diff >/dev/null 2>&1 || die \
	'diff not found. Install the diffutils package and try again.'

# --dry-run never prompts and never writes, so it needs no terminal: there is
# nothing for it to guess about. Everywhere else, refusing to guess which way a
# prompt would have been answered is the point.
if ((dry_run == 0)) && { [[ ! -t 0 ]] || [[ ! -t 1 ]]; }; then
	if ((assume_yes == 0 && keep_existing == 0)); then
		die 'no terminal to ask at: re-run with --yes or --keep-existing'
	fi
fi

# ---------------------------------------------------------------------------
# Walking the repository
# ---------------------------------------------------------------------------

if [[ ! -d $SRC_DIR ]]; then
	log 'no home/ directory in the repository, nothing to install'
	exit 0
fi

# Every regular file under home/ is a Managed File. Nested .git directories are
# the sole exception: they are not configuration and are never installed.
# Symlinks under home/ are dereferenced -- the contents are installed as regular
# files, because this repository does not reproduce symlinked layouts.
mapfile -d '' managed_files < <(
	find "$SRC_DIR" -mindepth 1 -name .git -prune -o \
		\( -type f -o -type l \) -print0 | sort -z
)

if ((${#managed_files[@]} == 0)); then
	log 'home/ contains no files, nothing to install'
	exit 0
fi

# ---------------------------------------------------------------------------
# Per-file handling
# ---------------------------------------------------------------------------

# Echo a reason and return 1 if any ancestor directory of the destination is
# either a symlink or not a directory. Both mean the install would either write
# outside Home or fail partway. Never write through a symlinked directory.
destination_blocker() {
	local rel=$1
	local -a parts=()
	local cur=$DEST
	local i

	IFS='/' read -r -a parts <<<"$rel"

	# Every component except the last is a directory we have to descend into.
	for ((i = 0; i < ${#parts[@]} - 1; i++)); do
		[[ -n ${parts[i]} ]] || continue
		cur="$cur/${parts[i]}"
		if [[ -L $cur ]]; then
			printf 'symlink: %s' "$cur"
			return 0
		fi
		if [[ -e $cur && ! -d $cur ]]; then
			printf 'not a directory: %s' "$cur"
			return 0
		fi
	done
	return 1
}

relative_display() {
	local rel=$1
	printf '~/%s' "$rel"
}

# Copy one Managed File, preserving its mode so executable scripts stay
# executable. The mode is read with stat and applied numerically rather than
# with `chmod --reference`, which is a GNU extension absent from BusyBox.
# Returns non-zero if the filesystem refused, without saying which step failed.
write_file() {
	local src=$1
	local dst=$2
	local parent mode

	parent=$(dirname -- "$dst")
	mkdir -p -- "$parent" || return 1

	mode=$(file_mode "$src")
	# Create the destination already carrying the right mode rather than
	# creating it and correcting it afterwards, so the file is never briefly
	# readable with the wrong permissions.
	(umask 0 && cp -- "$src" "$dst") || return 1
	chmod "$mode" -- "$dst" || return 1
	return 0
}

file_mode() {
	stat -c '%a' -- "$1"
}

# Decide what to do with a drifted file. Sets the 'outcome' variable to
# overwrite, keep, or abort.
decide() {
	local rel=$1
	local src=$2
	local dst=$3
	local answer

	outcome=abort

	if ((keep_existing)); then
		outcome=keep
		return
	fi
	if ((assume_yes)); then
		outcome=overwrite
		return
	fi

	while true; do
		printf '\n'
		show_difference "$rel" "$src" "$dst"
		printf -- '--- overwrite %s? [Y]es (default) / [n]o / [a]ll / [q]uit ---\n' \
			"$(relative_display "$rel")"
		printf '> '

		if ! read -r answer; then
			# End of input: treat as quit rather than guessing.
			outcome=abort
			return
		fi
		answer=${answer,,}
		case $answer in
		'' | y | yes)
			outcome=overwrite
			return
			;;
		n | no)
			outcome=keep
			return
			;;
		a | all)
			assume_yes=1
			outcome=overwrite
			return
			;;
		q | quit)
			outcome=abort
			return
			;;
		*)
			printf 'unrecognised answer, try again\n'
			;;
		esac
	done
}

show_difference() {
	local rel=$1
	local src=$2
	local dst=$3
	diff -u --label "installed: $(relative_display "$rel")" \
		--label "repository: home/$rel" \
		-- "$dst" "$src" || true
}

for src in "${managed_files[@]}"; do
	rel=${src#"$SRC_DIR"/}
	rel=${rel#/}
	dst="$DEST/$rel"
	display=$(relative_display "$rel")

	# A symlink under home/ that does not resolve to a file is not installable.
	if [[ -L $src && ! -f $src ]]; then
		refuse "home/$rel is a symlink that does not resolve to a file"
		continue
	fi

	if blocker=$(destination_blocker "$rel"); then
		refuse "$display: $blocker; refusing to install"
		continue
	fi

	# A file where we need a directory, or a directory where we need a file.
	if [[ -d $dst && ! -L $dst ]]; then
		refuse "$display is a directory but the repository has a file there"
		continue
	fi

	if [[ -L $dst ]]; then
		if ((dry_run)); then
			log "would replace symlink with regular file: $display"
		else
			rm -f -- "$dst" || {
				refuse "$display: could not remove symlink"
				continue
			}
			log "replaced symlink: $display"
		fi
	fi

	# Missing in Home: install silently. This is the fresh-machine path, and it
	# is the reason a fresh install needs no prompts at all.
	if [[ ! -e $dst ]]; then
		if ((dry_run)); then
			log "would install: $display"
		elif write_file "$src" "$dst"; then
			log "installed: $display"
			installed=$((installed + 1))
		else
			refuse "$display: could not write"
		fi
		continue
	fi

	if cmp -s -- "$src" "$dst"; then
		# Identical content. A mode difference is real Drift but carries no risk,
		# because the bytes are the same, so fix it without asking.
		if [[ $(file_mode "$src") != $(file_mode "$dst") ]]; then
			if ((dry_run)); then
				log "would fix mode: $display"
			elif chmod "$(file_mode "$src")" -- "$dst"; then
				log "fixed mode: $display"
				mode_fixed=$((mode_fixed + 1))
			else
				refuse "$display: could not set mode"
			fi
		else
			log "in sync: $display"
			in_sync=$((in_sync + 1))
		fi
		continue
	fi

	# Genuine Drift.
	# --dry-run never prompts and never writes. It reports what a real run would
	# do with each file, which for a drifted file is "ask", unless a flag has
	# already decided the answer.
	if ((dry_run)); then
		show_difference "$rel" "$src" "$dst"
		would_change=$((would_change + 1))
		if ((keep_existing)); then
			log "would keep: $display"
		elif ((assume_yes)); then
			log "would overwrite: $display"
		else
			log "would prompt before overwriting: $display"
		fi
		continue
	fi

	decide "$rel" "$src" "$dst"
	case $outcome in
	overwrite)
		if write_file "$src" "$dst"; then
			log "overwrote: $display"
			overwritten=$((overwritten + 1))
		else
			refuse "$display: could not write"
		fi
		;;
	keep)
		log "kept: $display"
		kept=$((kept + 1))
		;;
	abort)
		if ((quit_early == 0)); then
			quit_early=1
			log 'stopped, the rest of the repository was not installed'
		fi
		break
		;;
	esac
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\n'
if ((dry_run)); then
	log "dry run: nothing was written"
fi
log "installed ${installed}, in sync ${in_sync}, mode fixed ${mode_fixed}, overwritten ${overwritten}, kept ${kept}, refused ${refused}${would_change:+, would change ${would_change}}"

if ((refused > 0)); then
	exit 1
fi
if ((kept > 0 || quit_early == 1 || would_change > 0)); then
	exit 2
fi
exit 0
