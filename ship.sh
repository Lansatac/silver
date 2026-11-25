#!/bin/sh
# Puts the files named as arguments (paths under build/) into the same place under out/: hard linked, or
# copied where that fails, as across volumes, and left alone when already the same file. Skips one that
# build/ doesn't have yet. Each build that makes a shipped file runs this for it, since redub runs
# post-build commands only when it links, so a deleted one comes back with redub build --force.
cd "$(dirname "$0")" || exit 1
for f in "$@"; do
    [ -e "build/$f" ] || continue
    mkdir -p "out/$(dirname "$f")"
    [ "build/$f" -ef "out/$f" ] || ln -f "build/$f" "out/$f" 2>/dev/null || cp -f "build/$f" "out/$f" || exit 1
done
