#!/usr/bin/env bash
# Sets up the container's clone of Silver in /code, a volume, from the Windows clone mounted at
# /mnt/windows-silver. The two are separate repositories, since building on the Windows drive
# from Linux is several times slower. Files that are shared rather than versioned (the notes,
# CLAUDE.local.md, exploration) have one copy, in the Windows clone, and are linked from here.
# Safe to run again: it only adds what's missing.
set -euo pipefail

windows=/mnt/windows-silver
code=/code

if [ ! -d "$code/.git" ]; then
    # From the Windows clone rather than GitHub, so unpushed work comes along and no credentials
    # are needed. `windows` stays a remote for moving commits between the two.
    git clone --origin windows "$windows" "$code"
    git -C "$code" remote add origin "$(git -C "$windows" remote get-url origin)"
    if git -C "$code" fetch origin; then
        git -C "$code" branch --set-upstream-to=origin/master master
    else
        echo "setup: couldn't fetch origin; master tracks windows/master until you run git fetch origin"
    fi
fi

for name in notes CLAUDE.local.md exploration; do
    if [ -e "$windows/$name" ] && [ ! -e "$code/$name" ] && [ ! -L "$code/$name" ]; then
        ln -s "$windows/$name" "$code/$name"
    fi
done

# The Windows clone's excludes, plus forms without a trailing slash: a link to a directory
# isn't a directory, so `/notes/` and .gitignore's `/exploration/` don't match it.
exclude="$code/.git/info/exclude"
if [ -f "$windows/.git/info/exclude" ] && ! grep -q "^# From the Windows clone" "$exclude"; then
    { echo "# From the Windows clone"; cat "$windows/.git/info/exclude"; } >> "$exclude"
fi
for pattern in /notes /exploration; do
    grep -qxF "$pattern" "$exclude" || echo "$pattern" >> "$exclude"
done

if [ -f "$windows/.claude/settings.json" ] && [ ! -e "$code/.claude/settings.json" ]; then
    mkdir -p "$code/.claude"
    cp "$windows/.claude/settings.json" "$code/.claude/settings.json"
fi

# Each clone has its own issue database, synced with `bd sync` through the Dolt remote that the
# Windows clone's config.yaml names. Without one, bootstrap would make an empty database that
# never meets the real one, so it's left for later.
beads_config="$windows/.beads/config.yaml"
if [ ! -d "$code/.beads" ]; then
    if [ -f "$beads_config" ] && grep -qE '^sync:|^\s+remote:' "$beads_config"; then
        mkdir -m 700 "$code/.beads"
        cp "$beads_config" "$code/.beads/config.yaml"
        (cd "$code" && bd bootstrap --non-interactive) \
            || echo "setup: bd bootstrap failed; run it in /code"
    else
        echo "setup: the Windows clone's beads has no sync remote, so this clone has no issues yet"
    fi
fi
