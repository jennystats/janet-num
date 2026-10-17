#!/bin/bash
# Build pinned libjn.so for the janet-num module (jennystats/num.janet at
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
# stock macOS has no sha256sum; its perl-based shasum reads the same
# "<hash>  <path>" checklist format
CHECKSUM="sha256sum"
[ "$(uname -s)" = Darwin ] && CHECKSUM="shasum -a 256"

if ! command -v gcc >/dev/null && ! command -v clang >/dev/null; then
  case "$(uname -s)" in
    Darwin) echo "error: no C compiler found - on macOS install one with: xcode-select --install" >&2 ;;
    Linux)  echo "error: no C compiler found - install one with: sudo apt install build-essential  (Debian/Ubuntu)" >&2
            echo "       or: sudo dnf install gcc  (Red Hat/Fedora) - or use clang with CC=clang" >&2 ;;
    *)      echo "error: no C compiler found - janet-num needs a C compiler (gcc or clang) to build libjn.so" >&2 ;;
  esac
  exit 1
fi
CC="${CC:-gcc}"
command -v "$CC" >/dev/null || CC=clang
command -v "$CC" >/dev/null || { echo "error: no C compiler found - janet-num needs gcc or clang to build libjn.so" >&2; exit 1; }

echo "$SRC_SHA256  $SRC" | $CHECKSUM -c -

mkdir -p "$DEST"
"$CC" -O2 -Wall -Wextra -shared -fPIC -o "$DEST/libjn.so" "$SRC"
echo "built: $DEST/libjn.so"
echo "usage : (import jennystats/num) - resolution: \$JANET_NUM_LIB, then the path above"
