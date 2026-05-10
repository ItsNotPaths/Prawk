#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_NAME="$(basename "$PROJECT_DIR")"
RELEASE_DIR="$(cd "$PROJECT_DIR/.." && pwd)/${PROJECT_NAME}-release"

usage() {
    cat <<EOF
usage: $(basename "$0") [--local] [--public --version vX.Y.Z [--notes "text"]]

  --local               build locally into <project>-release/ next to the project
  --public              trigger release.yml workflow via gh CLI
  --version <tag>       required when --public is used
  --notes <text>        optional release notes / body
EOF
}

DO_LOCAL=0
DO_PUBLIC=0
VERSION=""
NOTES=""

while [ $# -gt 0 ]; do
    case "$1" in
        --local)   DO_LOCAL=1; shift ;;
        --public)  DO_PUBLIC=1; shift ;;
        --version) VERSION="${2:-}"; shift 2 ;;
        --notes)   NOTES="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown flag: $1" >&2; usage; exit 1 ;;
    esac
done

if [ $DO_LOCAL -eq 0 ] && [ $DO_PUBLIC -eq 0 ]; then
    usage
    exit 1
fi

if [ $DO_LOCAL -eq 1 ]; then
    echo "==> Local build: $PROJECT_NAME -> $RELEASE_DIR"
    mkdir -p "$RELEASE_DIR"

    BIN="$RELEASE_DIR/$PROJECT_NAME"
    # Trimming flags layered on top of -d:danger/-d:strip/-d:lto:
    #   -d:danger                — drops range/bounds/nil/overflow checks (~33 KB).
    #                              Saves are atomic (saveAtomic, editor.nim) so a
    #                              silent crash can't corrupt files on disk.
    #   -d:noSignalHandler       — no nim SIGSEGV/SIGINT handler (~3 KB).
    #   --threads:off            — no thread runtime; we never createThread.
    #   --panics:on              — exception machinery → panics; smaller .text.
    #   --stackTrace:off /
    #     --lineTrace:off        — drops file:line strings used in tracebacks.
    #   -fno-pie / -no-pie       — drops .rela.dyn relocations (~10 KB win)
    #   -ffunction-sections /
    #     -fdata-sections /
    #     -Wl,--gc-sections      — discards unreachable funcs/data
    #   -fno-asynchronous-unwind-tables /
    #     -fno-unwind-tables     — drops .eh_frame (we don't unwind C++)
    #   -fno-stack-protector     — no canary; this is a desktop tool, not a
    #                              network-facing daemon.
    #   -Wl,--build-id=none      — drops the build-id note
    #   -Wl,-z,norelro           — minor; relro section trim
    ( cd "$PROJECT_DIR" && \
      nim c --opt:size -d:danger -d:strip -d:lto \
            -d:noSignalHandler \
            --threads:off --panics:on \
            --stackTrace:off --lineTrace:off \
            --passC:-fno-pie --passL:-no-pie \
            --passC:-ffunction-sections --passC:-fdata-sections \
            --passC:-fno-asynchronous-unwind-tables \
            --passC:-fno-unwind-tables \
            --passC:-fno-stack-protector \
            --passL:-Wl,--gc-sections \
            --passL:-Wl,--build-id=none \
            --passL:-Wl,-z,norelro \
            --out:"$BIN" src/prawk.nim )

    [ -f "$PROJECT_DIR/README.md" ]    && cp -f "$PROJECT_DIR/README.md"    "$RELEASE_DIR/" || true
    [ -f "$PROJECT_DIR/gpl-3.0.txt" ]  && cp -f "$PROJECT_DIR/gpl-3.0.txt"  "$RELEASE_DIR/" || true
    if [ -d "$PROJECT_DIR/themes" ]; then
        rm -rf "$RELEASE_DIR/themes"
        cp -R "$PROJECT_DIR/themes" "$RELEASE_DIR/themes"
    fi

    SIZE=$(du -h "$BIN" | cut -f1)
    echo "==> Local done: $BIN (${SIZE})"
fi

if [ $DO_PUBLIC -eq 1 ]; then
    if [ -z "$VERSION" ]; then
        echo "error: --public requires --version <tag>" >&2
        exit 1
    fi
    if ! command -v gh >/dev/null 2>&1; then
        echo "error: gh CLI not found; install it and run 'gh auth login'" >&2
        exit 1
    fi
    REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || true)
    if [ -z "$REPO" ]; then
        echo "error: not in a github repo (or gh not authenticated)" >&2
        exit 1
    fi
    WORKFLOW="release.yml"
    echo "==> Triggering $WORKFLOW on $REPO ($VERSION)"
    OLD_ID=$(gh run list --workflow="$WORKFLOW" --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || echo "")
    gh workflow run "$WORKFLOW" \
        --field version="$VERSION" \
        --field notes="$NOTES"
    echo "==> Waiting for run to register..."
    NEW_ID=""
    for i in $(seq 1 30); do
        sleep 2
        CUR_ID=$(gh run list --workflow="$WORKFLOW" --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || echo "")
        if [ -n "$CUR_ID" ] && [ "$CUR_ID" != "$OLD_ID" ]; then
            NEW_ID="$CUR_ID"
            break
        fi
    done
    if [ -z "$NEW_ID" ]; then
        echo "error: failed to detect new workflow run" >&2
        exit 1
    fi
    echo "==> Watching run $NEW_ID"
    gh run watch "$NEW_ID" --exit-status
fi
