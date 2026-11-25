#!/usr/bin/env bash
# Unpacks a release archive into an empty directory and runs and builds hello world on both backends with
# it, from a PATH with no D tools (and on Windows no clang either, so the archive's llvm/ has to do):
#   release/smoke.sh <archive>
set -euo pipefail
archive=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
work=$(mktemp -d)
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT

case $(uname -s) in
    MINGW*|MSYS*|CYGWIN*) windows=yes; exe=.exe ;;
    *) windows=no; exe= ;;
esac
hidden="dmd dub redub rdmd ldc2 ldmd2"
[ "$windows" = yes ] && hidden="$hidden clang clang.exe lld-link lld-link.exe"
path=
IFS=: read -ra dirs <<< "$PATH"
for dir in "${dirs[@]}"; do
    skip=no
    for tool in $hidden; do
        if [ -e "$dir/$tool" ]; then skip=yes; fi
    done
    if [ "$skip" = no ]; then path=$path:$dir; fi
done
export PATH=${path#:}
for tool in dmd dub redub; do
    if command -v $tool > /dev/null; then echo "$tool is still on the PATH" >&2; exit 1; fi
done
if [ "$windows" = yes ] && command -v clang > /dev/null; then echo "clang is still on the PATH" >&2; exit 1; fi
unset SILVER_CLANG SILVER_LLD SILVERC SILVER_REDUB

mkdir "$work/unpacked" "$work/project"
case $archive in
    *.tar.gz) tar -C "$work/unpacked" -xzf "$archive" ;;
    *.zip) if command -v 7z > /dev/null; then 7z x -bso0 -o"$work/unpacked" "$archive"; else unzip -q "$archive" -d "$work/unpacked"; fi ;;
esac
dir=$(echo "$work"/unpacked/*)
export PATH=$dir:$PATH

# Runs a command and prints its output without the carriage returns that programs on Windows write.
output() { "$@" | tr -d '\r'; }
# check <description> <expected> <command>...: fails saying which check failed and what it got.
check() {
    local what=$1 expected=$2 got status=0
    shift 2
    got=$("$@" 2>&1 | tr -d '\r'; exit "${PIPESTATUS[0]}") || status=$?
    if [ "$status" != 0 ]; then
        echo "FAILED: $what: exit status $status, output:" >&2
        echo "$got" >&2
        exit 1
    fi
    if [ "$got" != "$expected" ]; then
        echo "FAILED: $what: expected '$expected', got:" >&2
        echo "$got" >&2
        exit 1
    fi
    echo "ok: $what"
}

check "silver and silverc versions agree" "silver $(output silverc$exe --version | sed 's/^silverc //')" silver$exe --version
# Read-only, since a release may be installed where nobody can write.
chmod -R a-w "$dir" 2>/dev/null || true

cd "$work/project"
cat > hello.ag <<'SRC'
def main(): Unit {
    printl("hello, silver")
}
SRC
check "silver run (interpreter)" "hello, silver" silver$exe run hello.ag
check "silver run -b llvm" "hello, silver" silver$exe run -b llvm hello.ag
check "silver run -b llvm -O" "hello, silver" silver$exe run -b llvm -O hello.ag
check "silver build" "" silver$exe build -o "hello$exe" hello.ag
check "the built program runs" "hello, silver" "./hello$exe"
echo "smoke test passed: $(basename "$archive")"
