#!/bin/sh
# Puts what ships into out/: silver, silverc and the runtime's libraries, hard linked from build/ (copied
# where that fails, as across volumes). stdlib is a link made by loader's hook. Skips what build/ doesn't
# have yet, so it can run before a build, which restores a deleted out/silverc that redub, finding it
# up to date, doesn't run post-build commands for, as well as after one.
cd "$(dirname "$0")" || exit 1
mkdir -p out/runtime
for f in silver silverc runtime/libsilver_rt.a runtime/libphobos2.a; do
    [ -e "build/$f" ] || continue
    [ build/$f -ef out/$f ] || ln -f "build/$f" "out/$f" 2>/dev/null || cp -f "build/$f" "out/$f" || exit 1
done
