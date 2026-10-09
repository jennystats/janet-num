#!/bin/bash
# Build pinned libjn.so for the janet-num module (janet-num.janet at
# the repo root). The kernels build from the pinned C source in this
# repo (libs/janet-num.c) - a plain C library via core ffi, NOT a
# native module (no Janet symbols, no jpm). The installer verifies the
# source sha256 before compiling. Idempotent; re-run to rebuild (e.g.
# after a pin bump).
set -e
SRC_SHA256="a39f39cbff9339a26aa5660c0c78bf20f578610aae0c0caa8c7b525a784356a6"
DEST="$HOME/.local/lib/janet-num"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/janet-num.c"

command -v gcc >/dev/null || { echo "error: gcc not found - janet-num requires a C compiler" >&2; exit 1; }

echo "$SRC_SHA256  $SRC" | sha256sum -c -

mkdir -p "$DEST"
gcc -O2 -Wall -Wextra -shared -fPIC -o "$DEST/libjn.so" "$SRC"
echo "built: $DEST/libjn.so"
echo "usage : (import janet-num) - resolution: \$JANET_NUM_LIB, then the path above"
