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

echo "==> libvterm"
if [ -d "$VENDOR/libvterm" ] && [ -n "$(ls -A "$VENDOR/libvterm" 2>/dev/null)" ]; then
    echo "  already present: libvterm"
else
    echo "  cloning libvterm..."
    git clone --depth=1 "https://github.com/neovim/libvterm.git" "$VENDOR/libvterm"
    echo "  done."
fi

echo ""
echo "All deps ready."
