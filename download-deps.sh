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
if [ -d "$VENDOR/luigi" ] && [ -n "$(ls -A "$VENDOR/luigi" 2>/dev/null)" ]; then
    echo "  already present: luigi"
else
    echo "  cloning luigi..."
    git clone --depth=1 "https://github.com/nakst/luigi.git" "$VENDOR/luigi"
    echo "  done."
fi

echo "==> luiginim"
if [ -d "$VENDOR/luiginim" ] && [ -n "$(ls -A "$VENDOR/luiginim" 2>/dev/null)" ]; then
    echo "  already present: luiginim"
else
    echo "  cloning luiginim..."
    git clone --depth=1 "https://github.com/neroist/luigi.git" "$VENDOR/luiginim"
    echo "  done."
fi

echo "==> sdl2"
fetch "sdl2" \
    "https://github.com/libsdl-org/SDL/releases/download/release-2.30.11/SDL2-2.30.11.tar.gz" \
    "$VENDOR/sdl2"

echo "==> sdl2_ttf"
fetch "sdl2_ttf" \
    "https://github.com/libsdl-org/SDL_ttf/releases/download/release-2.24.0/SDL2_ttf-2.24.0.tar.gz" \
    "$VENDOR/sdl2_ttf"

echo ""
echo "All deps ready."
