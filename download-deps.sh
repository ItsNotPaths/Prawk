#!/usr/bin/env bash
# Fetches third-party deps into vendor/. Run once before building.
set -euo pipefail

VENDOR="$(cd "$(dirname "$0")" && pwd)/vendor"

fetch() {
    local name="$1"
    local url="$2"
    local dest="$3"
    local strip="${4:-1}"
    local filter="${5:-}"

    if [ -d "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
        echo "  already present: $(basename "$dest")"
        return
    fi

    echo "  downloading $name..."
    mkdir -p "$dest"
    if [ -n "$filter" ]; then
        curl -fsSL "$url" | tar xz --strip-components="$strip" -C "$dest" --wildcards "$filter"
    else
        curl -fsSL "$url" | tar xz --strip-components="$strip" -C "$dest"
    fi
    echo "  done."
}

echo "==> luigi"
if [ -d "$VENDOR/luigi" ] && [ -f "$VENDOR/luigi/luigi.h" ]; then
    echo "  already present: luigi"
else
    echo "  cloning luigi..."
    git clone --depth=1 "https://github.com/nakst/luigi.git" "$VENDOR/luigi"
    echo "  done."
fi

echo "==> freetype headers (for luigi.h freetype path)"
FT_HEADERS="$VENDOR/luigi/freetype"
if [ -d "$FT_HEADERS" ] && [ -f "$FT_HEADERS/ft2build.h" ]; then
    echo "  already present: freetype headers"
else
    TMP=$(mktemp -d)
    git clone --depth=1 -q "https://gitlab.freedesktop.org/freetype/freetype.git" "$TMP/freetype"
    mkdir -p "$FT_HEADERS"
    cp -r "$TMP/freetype/include/." "$FT_HEADERS/"
    rm -rf "$TMP"
    echo "  done."
fi

echo "==> libtmt"
if [ -d "$VENDOR/libtmt" ] && [ -n "$(ls -A "$VENDOR/libtmt" 2>/dev/null)" ]; then
    echo "  already present: libtmt"
else
    echo "  cloning libtmt..."
    git clone --depth=1 "https://github.com/deadpixi/libtmt.git" "$VENDOR/libtmt"
    echo "  done."
fi

# prawk's libtmt extensions: pending-wrap, DECSTBM scroll regions, OSC absorb,
# CSI catchall, autowrap (?7), Unicode locale init. Applied to the cloned vendor
# tree at build time so vendor/ stays clean and others can re-clone freely.
PATCH="$(cd "$(dirname "$0")" && pwd)/patches/libtmt-prawk.patch"
if [ -f "$PATCH" ]; then
    if (cd "$VENDOR/libtmt" && git apply --check --reverse "$PATCH" >/dev/null 2>&1); then
        echo "==> libtmt-prawk patch already applied"
    elif (cd "$VENDOR/libtmt" && git apply --check "$PATCH" >/dev/null 2>&1); then
        echo "==> applying libtmt-prawk patch"
        (cd "$VENDOR/libtmt" && git apply "$PATCH")
    else
        echo "error: libtmt-prawk patch neither applies cleanly nor is already" >&2
        echo "       applied — vendor/libtmt may be on an unexpected commit." >&2
        exit 1
    fi
fi

echo ""
echo "All deps ready."
