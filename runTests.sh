#!/usr/bin/env bash
# Runs every package's tests, then the root's. Extra arguments go to each package's test command.
# Conformance runs each compiled program optimized as well; SILVER_CONFORMANCE_UNOPTIMIZED=1 skips that.
# Packages are named relative to this directory (`:sema`, not `silver:sema`): dub can resolve a
# qualified name to another checkout of the package, such as a git worktree.
#
# Builds and tests with redub from Jason's fork (github.com/Lansatac/redub, branch test-root), which
# generates the dub_test_root that silver.testrunner needs and leaves dub.selections.json's entries
# alone: $SILVER_REDUB, else `redub` on the PATH (the dev container builds the fork into its image),
# else ~/redub/build/redub. Without one, dub does the same work more slowly.
# $SILVER_REDUB_PARALLEL is passed to redub as --parallel (auto, full, leaves or no): each dmd that
# compiles against sema takes gigabytes, and several at once can need more memory than a machine has.
cd "$(dirname "$0")" || exit 1

packages=(:ast :syntax :loader :sema :core :interpreter :codegen :testing :conformance :frontend)
failed=()

if [ -n "$SILVER_REDUB" ]; then
    redub="$SILVER_REDUB"
elif command -v redub > /dev/null; then
    redub="$(command -v redub)"
else
    redub="$HOME/redub/build/redub"
fi
options=()
if [ -x "$redub" ]; then
    tool=("$redub")
    [ -n "$SILVER_REDUB_PARALLEL" ] && options=("--parallel=$SILVER_REDUB_PARALLEL")
else
    echo "note: redub wasn't found, so dub builds and tests. See the comment at the top of $0."
    tool=(dub)
fi

# The front end's end-to-end tests run the built silver and silverc.
echo "=== build"
"${tool[@]}" build "${options[@]}" || failed+=(build)

for package in "${packages[@]}" root; do
    echo "=== $package"
    if [ "$package" = root ]; then
        "${tool[@]}" test "${options[@]}" "$@" || failed+=("$package")
    else
        "${tool[@]}" test "$package" "${options[@]}" "$@" || failed+=("$package")
    fi
done

echo
if [ ${#failed[@]} -eq 0 ]; then
    echo "All $(( ${#packages[@]} + 1 )) packages passed."
else
    echo "Failed: ${failed[*]}"
    exit 1
fi
