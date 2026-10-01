#!/usr/bin/env bash
#
# Resize the shortest side of one image to 2160, keeping its codec.
#
#   img-resize-2160.sh holiday.jpg   ->   holiday-2160.jpg
#
# No logic here on purpose. This is img-resize.sh with the size filled in, so
# the arithmetic, the output naming and the rotation handling exist in exactly
# one place. The size is passed in the environment and the name of this script
# in IL_PROG_NAME, so that `img-resize-2160.sh --help` describes the size it
# actually uses rather than a size the caller has to supply.
#
# Needs libvips. See `img-resize.sh --doctor`.

set -euo pipefail

RESIZE_LIB_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
if [[ ! -r $RESIZE_LIB_DIR/img-resize.sh ]]; then
	printf '%s: cannot find img-resize.sh next to %s\n' \
		"$(basename -- "$0")" "$0" >&2
	exit 1
fi

IL_PINNED=2160 IL_PROG_NAME=$(basename -- "$0") \
	exec "$RESIZE_LIB_DIR/img-resize.sh" "$@"
