#!/usr/bin/env bash
#
# Download every URL in a list file with curl.
#
# Each line of the list contributes its first whitespace-separated field as the
# URL; whatever follows it -- a title, a note -- is ignored, and blank lines are
# skipped. A list written for a person to read therefore works as it is.
#
# Files are named after a fresh UUID rather than after what they hold, so a
# rerun never collides with a download that already exists and the names say
# nothing about what is in them. The extension is taken from the last path
# segment of the URL when there is a plain one to take, and dropped otherwise:
# a query string or a URL ending in a directory must not end up in the name.
#
# The proxy is opt-in: --proxy says whether to use one, $VPN_PROXY says where it
# is. The address is never a command-line option of its own, so it can be set
# once for a session instead of remembered by whoever runs this.

set -euo pipefail

DF_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
if [[ ! -r $DF_DIR/tool-lib.sh ]]; then
	printf '%s: cannot find tool-lib.sh next to %s\n' \
		"$(basename -- "$0")" "$0" >&2
	exit 1
fi
# shellcheck source=tool-lib.sh
source "$DF_DIR/tool-lib.sh"

TOOL_PROG=$(basename -- "$0")

usage() {
	cat <<-EOF
		Usage: $TOOL_PROG [OPTIONS] <list-file>

		Download each URL in LIST-FILE with curl, one file per URL, named
		after a fresh UUID.

		Each line contributes its first whitespace-separated field as the
		URL; the rest of the line is ignored, and blank lines are skipped
		and counted, so a list carrying titles alongside its links is read
		as written. LIST-FILE may be - to read the list from standard input.

		--proxy sends the downloads through the proxy at \$VPN_PROXY, which
		must be set for that flag. Without it no proxy is used, whatever
		VPN_PROXY holds.

		--dry-run prints each curl command instead of running it, so a
		list can be read through before anything is fetched.

		--interactive, --recursive, --directory and --undo-log are not for
		this tool: there is no tree to walk and nothing a download can be
		put back to.

	$(to_help_options)

		Examples:
		  # Download every URL in a file
		    $TOOL_PROG urls.txt

		  # Print the curl commands without running them
		    $TOOL_PROG --dry-run urls.txt

		  # Take the list from a pipe
		    cat urls.txt | $TOOL_PROG -

		  # Through the proxy, address taken from the environment
		    $TOOL_PROG --proxy urls.txt
	EOF
}

if to_wants_help "$@"; then
	if (( TOOL_WANTS_VERSION )); then
		printf '%s %s\n' "$TOOL_PROG" "$TOOL_VERSION"
	else
		usage
	fi
	exit 0
fi

# --proxy is this tool's own flag, and to_getopts dies on an option it does not
# know, so it is lifted out of the arguments before the shared parser runs. The
# scan stops at `--`, which is where option parsing stops for every tool here.
use_proxy=0
rest=()
parsing=1
for arg in "$@"; do
	if (( ! parsing )); then
		rest+=("$arg")
		continue
	fi
	case $arg in
		--)
			parsing=0
			rest+=("$arg")
			;;
		-p | --proxy)
			use_proxy=1
			;;
		--proxy=*)
			to_die "--proxy takes no value; the address comes from \$VPN_PROXY"
			;;
		*)
			rest+=("$arg")
			;;
	esac
done

to_getopts ${rest[@]+"${rest[@]}"}

# The four shared flags that describe work this tool does not do. They are
# refused rather than ignored: --undo-log for instance would be accepted,
# validated and then record nothing.
if (( TOOL_INTERACTIVE || TOOL_RECURSIVE || TOOL_ROOT_SET )) || [[ -n $TOOL_LOG ]]; then
	to_die "--interactive, --recursive, --directory and --undo-log are not for this tool: it reads a list and runs curl"
fi

if (( ${#TOOL_ARGS[@]} != 1 )); then
	usage >&2
	to_die "expected a list file, got ${#TOOL_ARGS[@]}"
fi

LIST=${TOOL_ARGS[0]}
if [[ $LIST == - ]]; then
	:
elif [[ -d $LIST ]]; then
	to_die "not a file: $LIST"
elif [[ ! -r $LIST ]]; then
	to_die "cannot read list: $LIST"
fi

if (( use_proxy )) && [[ -z ${VPN_PROXY:-} ]]; then
	to_die "--proxy needs VPN_PROXY set, e.g. export VPN_PROXY=http://10.65.141.170:8888"
fi

to_require_cmd curl
to_require_cmd uuidgen
to_counters_reset

proxy_args=()
if (( use_proxy )); then
	proxy_args=(--proxy "$VPN_PROXY")
fi

# The name the download would be written to.
#
# The query string and the fragment are dropped first, so
# `report.pdf?dl=1#page2` is a pdf and not `pdf?dl=1#page2`. The authority is
# dropped next: `http://example.com` holds no file, and without this it would
# offer `com` as its extension. What is left is the path, and only its last
# segment is looked at, so `example.com/a/report.pdf` is a pdf and
# `example.com/dir/` is nothing. A segment starting with a dot is a dotfile and
# has no extension, and what follows the dot otherwise has to be letters and
# digits to count: anything else -- a trailing dot, an encoded name -- means
# there is no extension to take, and the file is named after the UUID alone.
#
# Prints the extension without its dot, or nothing at all.
df_ext_of() {
	local path base ext

	path=${1%%#*}
	path=${path%%\?*}

	# A URL with no slash after its authority names a host, not a file.
	path=${path#*://}
	if [[ $path != */* ]]; then
		return 0
	fi
	path=${path#*/}

	base=${path##*/}
	if [[ $base == .* || $base != *.* ]]; then
		return 0
	fi

	ext=${base##*.}
	if [[ $ext =~ ^[[:alnum:]]+$ ]]; then
		printf '%s' "$ext"
	fi
}

entries=0

# Walk the list. Called with the file on stdin, or straight on stdin for `-`,
# which is why this is a function: a redirect is chosen once, at the call.
#
# `read` returns non-zero at EOF; the `|| [[ -n $line ]]` keeps the last line
# when the file ends without a newline, which a list typed by hand often does.
run_list() {
	local line url ext name cmd

	while IFS= read -r line || [[ -n $line ]]; do
		# Leading whitespace first, so an indented line is a URL and not
		# a blank one: the trim leaves the leading run of blanks behind,
		# and removing that leaves the line itself.
		line=${line#"${line%%[![:space:]]*}"}
		if [[ -z $line ]]; then
			TOOL_SKIPPED=$(( TOOL_SKIPPED + 1 ))
			continue
		fi

		# Split on the first run of whitespace: the field after it is a
		# title or a note, and handing it to curl as well would make it
		# a second, wrong URL.
		url=${line%%[[:space:]]*}
		entries=$(( entries + 1 ))

		ext=$(df_ext_of "$url")
		name=$(uuidgen)
		if [[ -n $ext ]]; then
			name+=".$ext"
		fi

		if (( TOOL_DRY_RUN )); then
			# The command as it would run, proxy argument included, so
			# the name in it is the name the file would really be given.
			cmd="curl --fail --show-error --silent -L"
			if (( use_proxy )); then
				cmd+=" --proxy $VPN_PROXY"
			fi
			printf '%s -o %s %s\n' "$cmd" "$name" "$url"
			TOOL_PLANNED=$(( TOOL_PLANNED + 1 ))
			continue
		fi

		# Said before the attempt, so a failed download still shows the
		# name it was aiming for: the UUID is the only link between the
		# URL and the file, and it is gone if the run stops here.
		printf '%s -> %s\n' "$url" "$name"

		# One dead URL does not end the batch: the rest of the list is
		# still worth downloading, and the summary reports the failure.
		#
		# --fail makes an HTTP error a non-zero exit, so a 404 is a
		# failure rather than an error page saved under a UUID; the
		# partial file it may have started is removed, so a dead
		# connection leaves nothing behind but the report.
		if curl --fail --show-error --silent -L \
			${proxy_args[@]+"${proxy_args[@]}"} \
			-o "$name" "$url"; then
			TOOL_CHANGED=$(( TOOL_CHANGED + 1 ))
		else
			TOOL_FAILED=$(( TOOL_FAILED + 1 ))
			rm -f -- "$name"
			to_warn "curl failed for $url"
		fi
	done
}

if [[ $LIST == - ]]; then
	run_list
else
	run_list < "$LIST"
fi

# A list with no URL in it is a mistyped path more often than a deliberate
# request to do nothing, and "0 downloaded" alone reads like success. Said
# before the summary, so an empty run cannot come back green.
if (( entries == 0 )); then
	if [[ $LIST == - ]]; then
		to_warn "no URLs on standard input"
	else
		to_warn "no URLs in $LIST"
	fi
	exit "$TOOL_EX_USAGE"
fi

status=$TOOL_EX_OK
to_summary '' 'downloaded' 'to download' || status=$?
exit "$status"
