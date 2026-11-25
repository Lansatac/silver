#!/usr/bin/env bash
# Builds silver and silverc as a release does and archives out/ as real files:
#   release/package.sh [--no-build] [--llvm <dir holding clang and lld-link>] [--dist <dir>]
# Writes <dist>/silver-<version>-<os>-x64.(tar.gz|zip) and its .sha256 (default dist: dist/).
# SILVER_REDUB and SILVER_REDUB_PARALLEL are as for runTests.sh.
# The version is SILVER_VERSION or what the build stamps from the tag's describe; a release's workflow
# sets it from the tag. --no-build archives the out/ already there. On Windows (Git Bash) --llvm names the
# directory whose clang.exe and lld-link.exe go in llvm/, since silverc looks for them beside itself;
# Linux has no llvm/, since there you bring your own clang and C development files.
# Builds with the silver-release build type (dub.json): optimized, keeping asserts, which lowering and
# the backends use for what sema has already rejected.
set -euo pipefail
cd "$(dirname "$0")/.."

build=yes
llvm=
dist=$PWD/dist
while [ $# -gt 0 ]; do
    case $1 in
        --no-build) build=no ;;
        --llvm) llvm=$2; shift ;;
        --dist) dist=$2; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

case $(uname -s) in
    MINGW*|MSYS*|CYGWIN*) os=windows; exe=.exe ;;
    Linux) os=linux; exe= ;;
    *) echo "unsupported platform: $(uname -s)" >&2; exit 1 ;;
esac
if [ "$os" = windows ] && [ -z "$llvm" ]; then
    echo "--llvm is required on Windows" >&2
    exit 2
fi

if [ -n "${SILVER_REDUB:-}" ]; then redub=$SILVER_REDUB
elif command -v redub > /dev/null; then redub=redub
else redub=$HOME/redub/build/redub; fi

if [ "$build" = yes ]; then
    # silver, which the root's pre-generate hook builds with the default build type, only finds a project and
    # starts silverc, so it has no build type of its own.
    options=()
    [ -n "${SILVER_REDUB_PARALLEL:-}" ] && options=("--parallel=$SILVER_REDUB_PARALLEL")
    "$redub" build -b silver-release --force "${options[@]}"
fi

version=$(out/silverc$exe --version | tr -d '\r' | sed 's/^silverc //')
[ "$(out/silver$exe --version | tr -d '\r')" = "silver $version" ] || { echo "silver and silverc differ in version" >&2; exit 1; }
name=silver-$version-$os-x64
stage=$dist/$name
rm -rf "$stage"
mkdir -p "$stage/licenses"

cp "out/silver$exe" "out/silverc$exe" "$stage/"
cp -rL out/stdlib "$stage/stdlib"
cp -r out/runtime "$stage/runtime"
cp LICENSE "$stage/licenses/Silver-LICENSE.txt"

# The texts are kept in release/licenses: Phobos and druntime (in runtime/), zlib (which Phobos includes),
# and for Windows LLVM and MinGW-w64.
cp release/licenses/Phobos-*.txt release/licenses/zlib-*.txt "$stage/licenses/"

cat > "$stage/licenses/README.txt" <<NOTE
Silver is MIT licensed (Silver-LICENSE.txt). The executables and runtime/ also carry the D runtime and
standard library (Phobos), Boost licensed, with the zlib code Phobos includes.
NOTE

if [ "$os" = windows ]; then
    mkdir "$stage/llvm"
    cp "$llvm/clang.exe" "$llvm/lld-link.exe" "$stage/llvm/"
    cp release/licenses/LLVM-*.txt release/licenses/mingw-*.txt "$stage/licenses/"
    cat >> "$stage/licenses/README.txt" <<NOTE
llvm/ holds clang and lld-link (LLVM, Apache-2.0 with LLVM exceptions: LLVM-LICENSE.txt), and runtime/mingw
the MinGW-w64 libraries that programs link against (mingw-w64-*.txt).
NOTE
fi

mkdir -p "$dist"
rm -f "$dist/$name.tar.gz" "$dist/$name.zip"
if [ "$os" = linux ]; then
    archive=$name.tar.gz
    tar -C "$dist" -czf "$dist/$archive" "$name"
else
    archive=$name.zip
    if command -v 7z > /dev/null; then
        (cd "$dist" && 7z a -tzip -bso0 "$archive" "$name")
    else
        (cd "$dist" && powershell -NoProfile -Command "Compress-Archive -Path '$name' -DestinationPath '$archive'")
    fi
fi
(cd "$dist" && sha256sum "$archive" > "$archive.sha256")
echo "$dist/$archive"
cat "$dist/$archive.sha256"
