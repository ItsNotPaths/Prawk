#!/usr/bin/env bash
# Materialize a patched copy of vendored luiginim into build/luiginim so the
# vendor/ tree stays byte-identical to upstream. See
# patches/luiginim-dyn-freetype.patch for what and why.
#
# Idempotent: no-op when build/luiginim is newer than both the source tree
# and the patch file.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SRC=vendor/luiginim
DST=build/luiginim
PATCH=patches/luiginim-dyn-freetype.patch
STAMP=build/.luiginim.stamp

need_rebuild() {
    [ ! -f "$STAMP" ] && return 0
    [ "$PATCH" -nt "$STAMP" ] && return 0
    if [ -n "$(find "$SRC" -type f -newer "$STAMP" -print -quit)" ]; then
        return 0
    fi
    return 1
}

if need_rebuild; then
    echo "==> prep-vendor: applying $PATCH"
    rm -rf "$DST"
    mkdir -p build
    cp -r "$SRC" "$DST"
    patch -p1 -s -d "$DST" <"$PATCH"
    touch "$STAMP"
fi
