#!/usr/bin/env bash
# Runs every package's tests, then the root's. Extra arguments go to each `dub test`.
# Conformance runs each compiled program optimized as well; SILVER_CONFORMANCE_UNOPTIMIZED=1 skips that.
# Packages are named relative to this directory (`:sema`, not `silver:sema`): dub can resolve a
# qualified name to another checkout of the package, such as a git worktree.
cd "$(dirname "$0")" || exit 1

packages=(:ast :syntax :loader :sema :core :interpreter :codegen :testing :conformance :frontend)
failed=()

# The front end's end-to-end tests run the built silver and silverc.
echo "=== build"
dub build || failed+=(build)

for package in "${packages[@]}" root; do
    echo "=== $package"
    if [ "$package" = root ]; then
        dub test "$@" || failed+=("$package")
    else
        dub test "$package" "$@" || failed+=("$package")
    fi
done

echo
if [ ${#failed[@]} -eq 0 ]; then
    echo "All $(( ${#packages[@]} + 1 )) packages passed."
else
    echo "Failed: ${failed[*]}"
    exit 1
fi
