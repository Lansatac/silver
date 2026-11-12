#!/usr/bin/env bash
# Runs every package's tests, then the root's. Extra arguments go to each `dub test`.
cd "$(dirname "$0")" || exit 1

packages=(silver:ast silver:syntax silver:loader silver:sema silver:core silver:interpreter silver:codegen silver:testing silver:conformance silver)
failed=()

for package in "${packages[@]}"; do
    echo "=== $package"
    if ! dub test "$package" "$@"; then
        failed+=("$package")
    fi
done

echo
if [ ${#failed[@]} -eq 0 ]; then
    echo "All ${#packages[@]} packages passed."
else
    echo "Failed: ${failed[*]}"
    exit 1
fi
