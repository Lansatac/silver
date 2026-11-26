# The `silver` tool

`silver` is what a programmer runs. It finds the project a file belongs to, reads the project's package file, and calls the compiler, `silverc`, with what it found. What a [package](language/modules.md#packages) is, and every rule about one, belongs to the language and to `silverc`. Where a package's source is, and how that's written down, belongs to `silver`.

## Commands

```
silver hello.ag            run a file
silver run hello.ag        the same
silver build hello.ag      compile it to an executable
silver test sema           run the tests in a file or a directory
silver run                 run the program of the project here
silver build               compile it
silver test                run the tests of the project here
silver update              fetch remote packages again and rewrite silver.lock
```

- The first word is a command only when it's one of `silver`'s. Anything else is a file, so a file named `build` is run as `silver ./build`.
- What follows the file is for the program, not for `silver`: its [arguments](language/programs.md#arguments). With no file, or with a package's directory, they follow `--`, as `silver run -- notes.txt` and `silver run compiler -- main.ag`. One rule covers all three: the first `--` after the file, the directory or nothing is dropped, and the rest is the program's. So `silver run tool.ag -- x` gives `["x"]` as `silver run tool.ag x` does, `silver run tool.ag -- -- x` gives `["--", "x"]`, and `silver run tool.ag a -- b` gives `["a", "--", "b"]`. `silverc` follows the same rule after a file and after `--program`.
- A file can start with `#!/usr/bin/env silver` and be run as `./hello.ag`.
- With no file, `run` and `build` take the program of the package `silver` was started in. A library is reported as one. When several of the packages a file describes are programs, `silver` lists them, and one is chosen by its directory, as `silver run compiler`. A package with a `silver.toml` of its own is run from its own directory, or by naming it, as `silver run tools/lint`.
- With no path, `test` runs the tests of the package `silver` was started in, as `test` over its directory. From the directory of a `silver.toml`, that's what the file names, as [What `silver test` tests](#what-silver-test-tests) describes; from the directory of a package it describes, that package.
- `test` over a directory tests what the nearest `silver.toml` at or above it names under it, and nothing it doesn't. A directory under it with a `silver.toml` that the file doesn't name is another project, tested from its own directory, and is left out. A directory with no `silver.toml` at or above it names nothing: its scripts are tested, and every project under it is left out. To test a folder of projects together, give it a `silver.toml` that lists them; today that file also needs a `source`, for the reason the last of the open questions gives.
- Naming a directory tests it, whatever an entry says: `test` on an entry decides what a wider run includes, not whether a package can be tested.
- However many places a run covers, it's one report with one summary, and `--format json` is one document.
- `silver --version` and `silverc --version` print one line, `silver 0.1.0` and `silverc 0.1.0`, and stop. Both are built from the same tree and print the same number. The number is the release's tag with its `v` taken off: built on the tag `v0.1.0` it's `0.1.0`. Between tags it's what `git describe` gives, the last tag, the commits since, and the commit: `0.1.0-12-g1a31aab`, with `-dirty` added when the working tree has uncommitted changes. That is a git describe string and not a SemVer pre-release, even though SemVer would sort it before `0.1.0`; it says which commit a build is from, not an order. With no `v` tag in the history (another tag's name never appears) it's `0.0.0-g` and the commit, and with no git history at all (a source archive) `0.0.0-dev`; setting `SILVER_VERSION` when building overrides all of these, which is how a release gives its tag's version whatever the checkout holds.
- `--show-command`, given before the file like any option, prints the command line `silver` runs the compiler with, then runs it. It's for when `silver` and `silverc` seem to disagree.

## Projects

A directory is a package when it holds a file named `silver.toml`, or when a `silver.toml` above it describes a package there. Nothing else makes one: a folder's name means nothing by itself.

```toml
# geometry/silver.toml
name = "geometry"
```

```
geometry/silver.toml
geometry/package.ag           module geometry
geometry/area.ag              module geometry.area
geometry/shapes/circle.ag     module geometry.shapes.circle
```

- `name` is the package's name, and has to be given. Each segment of it is written as a segment of a [module's name](language/modules.md#modules) is: a lowercase letter or `_`, then letters, digits and `_`. The same goes for the name of every package the file describes and every name in `uses`.
- The package's modules are in the file's own directory, unless `source` names a directory under it, as `source = "source"`.
- `uses` lists the packages this one uses, by name. A name is the file's own package or one that a `[[package]]` entry gives. The standard library isn't listed: every package uses it.
- `[[package]]` lists the packages the file tells `silver` about, one entry each, as below.
- A field `silver` doesn't know is an error.

```toml
# cards/silver.toml
name = "cards"
uses = ["geometry"]

[[package]]
path = "../geometry"
```

### The packages a file lists

Every package a file tells `silver` about, other than its own, is an entry under `[[package]]`, of one of three kinds:

- **Described here**, with a `name` and a `path`, and optionally `source` and `uses`. Its directory has no `silver.toml`: the package exists because this file says so. Its `path` is a directory under the file's.
- **With a file of its own**, with a `path` alone. Its name, `source`, `uses` and the packages it lists are read from the `silver.toml` in that directory, so nothing about it is repeated. It can be anywhere, inside the file's directory or elsewhere.
- **Remote**, with a `name` and where it comes from: a `git` repository, with a `tag`, `branch` or `rev`, or a `version` from the registry. [Remote packages](#remote-packages) describes them.

```toml
[[package]]                   # described here
name = "app.shapes"
path = "shapes"
uses = ["geometry"]

[[package]]                   # with a silver.toml of its own
path = "../geometry"

[[package]]                   # remote
name = "cards"
git = "https://github.com/someone/cards"
tag = "v0.3.0"
```

Any entry can say `test = true` or `test = false`, which decides whether `silver test` from this file tests it. An entry under the file's directory is tested unless it says `test = false`. One outside it is tested only when it says `test = true`, as a remote one will be. Where `test` gives what the entry's place gives anyway, it changes nothing.

A directory with a `path` alone needn't have a `silver.toml` of its own when the nearest one above it describes a package there. So a package elsewhere uses one package of another project by its directory, as `path = "../silver/core"`, and `silver` finds the file that describes it above.

### A project of several packages

A file can describe several packages, each with a name, a path and what it uses. The packages one file describes, its own among them, are one **project**, and share ownership of each other's declarations, as [Modules](language/modules.md#projects) describes. A package with a file of its own is its own project whoever lists it, so listing `std` or someone else's package gives no rights over its types. Here is the compiler:

```toml
# silver.toml
name = "silver"

[[package]]
name = "silver.ast"
path = "ast"

[[package]]
name = "silver.syntax"
path = "syntax"
uses = ["silver.ast"]

[[package]]
name = "silver.sema"
path = "sema"
uses = ["silver.ast", "silver.loader"]

[[package]]
name = "silver.compiler"
path = "compiler"
uses = ["silver.sema", "silver.core", "silver.interpreter", "silver.codegen"]

[[package]]
name = "silver.frontend"
path = "frontend"
```

```
silver.toml
ast/node.ag                   module silver.ast.node
sema/package.ag               module silver.sema
sema/check.ag                 module silver.sema.check
compiler/main.ag              module silver.compiler.main
```

- A described package's directory has no `silver.toml`. Its file is the one that describes it.
- `uses`, the file's own or a described package's, names packages among the file's entries, which every package the file describes shares.
- A described package's `source` works as a package's does.
- A package that describes others has modules of its own only when it gives `source`. Without it, as above, the package exists only to describe the others.
- Any number of the packages a file describes can be programs. Each with a `main` is one.
- A described package can't describe packages: it has no file to do it in. A package with a file of its own can list packages of its own, and those are in its project, not in the lister's.

### What `silver test` tests

`silver test` tests the packages its file names, and nothing it doesn't name.

- The file's own package, every package it describes, and every package it lists with a `silver.toml` of its own in a directory under its own are tested, unless the entry says `test = false`. Testing a listed package under the directory tests what `silver test` would test from that package's directory, by this same rule, so the run stays inside the one directory tree. Only the file `silver test` starts from opts in what's outside: a listed package's own `test = true` entries count when `silver test` starts from that package's directory, and not when it's reached from above.
- A package listed outside the file's directory is tested only when its entry says `test = true`. That tests its own project alone: its own package and the packages its file describes, not what its file lists, whatever those entries say. Its dependencies are found as for a package that's used, and aren't tested.
- A directory under one tested that holds a `silver.toml` the file doesn't name is another project, and is left out. Scripts under a tested package's directory, and in plain folders under the file's, are tested.

Here is the compiler with its standard library under it, its documentation's examples left out, and a library elsewhere that it opts in:

```toml
# silver.toml
name = "silver"

[[package]]
name = "silver.syntax"
path = "syntax"

[[package]]
name = "silver.compiler"
path = "compiler"
uses = ["silver.syntax", "geometry"]

[[package]]
name = "silver.docs"
path = "docs"
test = false

[[package]]
path = "std"                  # the standard library, with a silver.toml of its own

[[package]]
path = "../geometry"          # outside, a silver.toml of its own
test = true
```

```
silver test                   syntax, compiler, std, and ../geometry, in one report
silver test docs              docs, which is named
cd compiler && silver test    compiler alone
cd std && silver test         std, by its own silver.toml
```

A folder under the root with a `silver.toml` of its own that the root doesn't list, as a test fixture that's a project, is left out of all of these.

### Finding the project

- When a file is named, `silver` looks for `silver.toml` in the file's directory and then in each directory above it, and takes the first it finds. Where `silver` was started from doesn't matter, so a script run by its path behaves the same from anywhere.
- When no file is named, it looks the same way from the directory it was started in.
- A file belongs to the package whose directory of modules it's under.
- A file with a `module` line has to be named by its package's name followed by its path there.

## Remote packages

A remote package is one `silver` fetches. Its entry gives the package's `name`, and where the package comes from: a git repository, or the registry. Once fetched, it's a package with a `silver.toml` of its own, as one listed by its `path` is. Its file says what it uses and lists, and the project it belongs to is its own.

- `name` has to be given, and has to be the name the package's own file gives it. Its modules are named after it, so it's also the name the program imports. A remote entry has no `source` or `uses`, since the package's own file gives those.
- A remote package is tested only when its entry says `test = true`, as one outside the file's directory is.
- Every package of one name in a program is the same package, from one source at one commit. Two entries that give a name and reach different files are an error naming both, even when one is reached only through another package. A program can't hold two versions of a package.
- Fetching runs nothing from the package. `silver` reads what it fetches and never runs it.

### From git

```toml
[[package]]
name = "cardgames.cards"
git = "https://github.com/someone/cardgames"
path = "cards"
tag = "v0.3.0"
```

- `git` is the repository: an `https://` or `ssh://` URL, git's `user@host:path` form, or a directory on this machine. Nothing else is accepted.
- At most one of `tag`, `branch` and `rev` says what to take. A `rev` is a commit's full hash. With none, the repository's default branch.
- `path` is the package's directory inside the repository, and with none it's the repository's root. It's found as a `path` alone is: the directory has a `silver.toml` that names the package, or the nearest `silver.toml` above it in the repository describes a package there.
- `silver` uses `git` on the PATH to fetch, and needs it only when something isn't fetched yet. A repository that needs a login is fetched with whatever git uses for that.
- A remote package's own `path` entries have to stay inside its repository. Its own remote entries are followed in turn. Its own `silver.lock`, if it has one, is ignored.

### silver.lock

When `silver run`, `build` or `test` reaches a remote package, it records the commit taken in `silver.lock` beside the `silver.toml` it started from, along with a hash of the repository's files at that commit. After that, every run takes the same commit and checks the hash, so a moved tag or a changed repository can't change a build silently. A program's `silver.lock` belongs in version control with its `silver.toml`.

```toml
# silver.lock: written by silver
[[package]]
name = "cardgames.cards"
git = "https://github.com/someone/cardgames"
path = "cards"
tag = "v0.3.0"
commit = "4f1c2a9e0b7d3c58e6a1f92d4b0c7e3a5d8f1b26"
hash = "sha256-..."
```

- A remote package that isn't in the lock is fetched and added, and the run goes on. One already there is never moved by a run, even when its branch has moved on.
- An entry that no longer matches what's locked, because its `git`, `path`, `tag`, `branch` or `rev` changed, is fetched again; the rest stay as they are. A package no longer reached is dropped from the lock.
- `silver update` fetches every remote package again, taking a branch's or tag's current commit, and rewrites the lock. `silver update cardgames.cards` fetches just that one.
- `--locked` fails rather than change `silver.lock`, for CI. `--offline` never fetches: anything that isn't fetched yet is an error.
- The hash is of the files as git stores them, with no line endings converted, not of how they were fetched. So the same commit gives the same hash on every platform and wherever it comes from. A repository holding a symbolic link is refused.

Fetched packages are kept, read-only, in one cache that every project shares: `$XDG_CACHE_HOME/silver`, or `~/.cache/silver`, on Linux, and `%LOCALAPPDATA%\silver` on Windows. `SILVER_CACHE` names another. Anything in it can be fetched again, so it can be deleted.

### From the registry

The registry isn't built yet. What's decided:

- A package in the registry has a name of the form `@scope/name`. A scope belongs to an account, signed in with GitHub at first, and the account owns every name under it. The registry name is separate from the package's `name`: the entry gives both, and the program imports the `name`.
- `version = "1.2"` asks for at least 1.2.0 and below 2.0.0. Where several packages ask for one package, the version taken is the lowest that satisfies all of them: the highest of their minimums. So a newer release never changes a build until something asks for it. Requests for different major versions are an error, since a program holds one version of each package.
- A package in the registry can't use a package from git or by a path outside itself, so everything it uses is in the registry too.
- What's published stays published. A broken version can be yanked, which keeps a new lock from choosing it while builds that already locked it keep working.
- The registry holds only what's needed to find a version and check it. The code stays where its author keeps it, such as on GitHub, and is checked against the hash the registry recorded.

## Scripts

A file with no `module` line is a script: a whole program in one file, which nothing can import.

- With no `silver.toml` at or above it, a script uses the standard library and nothing else. No package file is ever needed to run one file.
- A script under a package's directory uses what that package uses. When the package is a library, the script uses the package too.
- A package's directory here is the one its `silver.toml` is in, and for a package a file describes its `path`, even when `source` puts the modules below it, so a script beside a `silver.toml` is under that package. When several hold a script, the deepest does, so a script in a described package's directory is under that package.
- A script never belongs to the package. It's a program of its own beside it.

So a library can keep runnable files beside its modules, each a program that uses it:

```
geometry/silver.toml
geometry/area.ag              module geometry.area
geometry/demo.ag              a script
geometry/benchmark.ag         another
```

```silver
// geometry/demo.ag, with no module line
import geometry.area

def main(): Unit { printl(area(Circle(2.0))) }
```

And a program can keep scripts under it that never import it, as a test harness keeps the programs it runs. Those see the packages the harness uses and not the harness.

## Open questions

- Importing a remote package under a name of its own choosing, so that two packages that give the same name can be in one program. A package's modules are named after it, so this needs the compiler to take a package's modules under another name. It would be a new key on the entry.
- Overriding a remote package, as the root project's `path` for a fork being worked on, in place of what the packages that use it ask for. Until then, two entries for one name that disagree are an error.
- One `silver.lock` for a project and the projects it lists by `path`. Today the lock is the one beside the `silver.toml` a run starts from, so a listed project run from its own directory locks on its own.
- Git submodules in a remote package's repository, which aren't fetched.
- The registry: the key that gives an entry's registry name, how `silver publish` adds a version, several registries, and a mirror that keeps a package's code when its repository is gone.
- Whether `std` is versioned apart from the compiler.
- A script that needs a package and sits in no project, or in a project but under none of its packages. A header in the script could say so.
- What an executable built from a described package is called when its name isn't wanted, as `silverc` for `silver.compiler`. The default name is the last segment of the package's name, which is usually also its directory, so where executables have no extension `silver build compiler` can't write its default output and asks for `-o`, even when that command is the one a message just suggested.
- Whether a package may have more than one module that declares `main`.
- A package used only by tests.
- Naming a prelude other than the standard one.
- Whether only what a run reaches should be read. Today every package a file describes is read and followed once any of them is reached, and every entry it lists is read, so one broken entry stops runs that never use it.
- Whether a directory with a `silver.toml` of its own should never count as part of an enclosing package's modules. Today two layouts need `source` on the outer package, since without it the outer package's modules are its whole directory and one package's directory can't be inside another's (`F0035`): a root that only lists packages with files of their own in its subfolders, as a folder of projects might, and a package that lists a dependency kept in a subfolder of itself. Leaving such directories out of the outer package's modules would allow both, and would change that rule.

## Current implementation

Everything above is built, with the narrowings and gaps listed at the end.

- `silver` and `silverc` are two programs. `silver` runs a file, builds one and tests a path by calling `silverc` once, with the same command and options and with what it read from the project added. It finds `silverc` beside itself, or where the environment variable `SILVERC` says. `silver` never reads a `.ag` file: whether a file is a script, and whether a package is a program, `silverc` decides.
- `silverc` finds the standard library in the directory `stdlib` beside itself, and the runtime that `silver build` links in the directory `runtime` beside itself. So `silver`, `silverc`, `stdlib` and `runtime` copied together to one directory work from there, on a machine that has no checkout of the compiler. It looks nowhere else: with no `stdlib` beside it, `silverc` says where it expected one and runs nothing, and with no `runtime`, `silver build` and the compiled backend say the same of it. The runtime is built along with the compiler, once and optimized, and every program links it, optimized or not. `silverc` only links it, with the druntime and Phobos it was built against, which are copied beside it, so `runtime` holds no sources and can be read-only. Building a program needs clang, which compiles it, and on Windows lld-link, which links it with only `runtime`'s libraries (MinGW's in place of Visual Studio's and the Windows SDK's), so Visual Studio isn't needed; a program built there needs nothing that Windows 10 doesn't have. `silverc` looks for clang in the directory `llvm` beside itself, where a Windows release bundles clang and lld-link, and then on the PATH; `SILVER_CLANG` and `SILVER_LLD` name others. On Linux, clang links too, with the system's linker and C library, so building a program also needs the C development files (Debian and Ubuntu's `libc6-dev`, which `build-essential` includes); a Windows release brings its tools, but on Linux you bring your own C. Building the compiler from a checkout puts all four in `out/`, and nothing else: `out/` is what a release archives, where `stdlib` is a link to the checkout's. Everything else a build makes, the intermediates (`.o` files, which redub hard-links into the target directory along with the executable), the test executables, `stampversion` and the runtime as built, goes to `build/`, and `ship.sh` (`ship.cmd` on Windows) puts `silver`, `silverc` and the runtime's libraries from there into `out/`: hard linked, or copied where that fails, as across volumes, and on Windows copied only when different. Each build that makes one ships it: the front end's post-build hook, the root's (which ships `silver` too, so a forced build after a delete brings both back), and codegen's hook after it builds the runtime. redub runs post-build commands only when it links, so if `out/` or `build/` is deleted, `redub build --force` restores `out/`; a plain `redub build` may not. The test executables find `stdlib` and `runtime` beside themselves in `build/`, where a link to `stdlib` and the runtime itself are.
- The version is stamped at build time: the `stampversion` program, built once into `build/` and run by a pre-generate hook of `silver` (which `silverc`'s build runs first, and its test build runs itself), writes `generated/version.txt` from `SILVER_VERSION` (a leading `v` is dropped) or `git describe --tags --match "v[0-9]*" --dirty`, and only when the content changes. The file is alone in its directory, which is the only string import path, so only a new version rebuilds anything, and only `silver` and `silverc`; a build with nothing else changed takes about a tenth of a second. Each of `silver` and `silverc` reads the file as a string import and prints it, since `silver` imports none of the compiler's packages and so can't ask it, and both come from one build. `silver` takes `--version` among the options before the file, as it does `--show-command`, and prints its own version whatever follows (`silver run --version`, `silver --version f.ag`); after the file it's the program's. `--help` wins over it.
- A release is made by pushing a tag `v<digit>*`: `.github/workflows/release.yml` runs `release/package.sh` on Linux and Windows, which builds with the `silver-release` build type (`-O -inline` without `-release`, so optimized but keeping asserts and bounds checks, since lowering and the backends assert what sema rejects, and dub's `release` drops them; `silver`, only a front end, is built with the default type) with `--force`, so a stale `out/` isn't archived, and assembles `silver`, `silverc`, `stdlib` (the files, not a link), `runtime` and `licenses` (kept in `release/licenses`) into a directory `silver-<version>-<os>-x64`, and archives it (`.tar.gz` on Linux, `.zip` on Windows) with a `.sha256`. The Windows archive adds `llvm` with `clang.exe` and `lld-link.exe`; the Linux one has none, since there you bring your own clang and C development files. Each archive is unpacked into an empty directory and `release/smoke.sh` runs and builds hello world with it on both backends, from a PATH without D tools (and on Windows without clang), with the archive read-only. The workflow publishes both as a GitHub Release with build provenance attestations; run by hand (`workflow_dispatch`) it builds and smoke tests without publishing. Only Windows and Linux x64 are built. The compiler is built with dmd, not LDC, since the runtime links the dmd Phobos that the rest of the build and its pins use.
- `silver --help` describes the front end's commands, and `silver <command> --help` that command's forms, pointing at `silverc --help` for the options. `silver help`, with no file of that name, says there's none and points at `silver --help`.

Reading the project:

- `silver` finds the project of the file or directory named, or of the working directory when none is, and reads its `silver.toml` and the files of the packages it lists, as above. A directory named `silver.toml` isn't a package file, and the search carries on above it. `-` as the file is passed on with no search for a project.
- A package file is read whole and checked before anything is run, and a mistake in it is one message located in the file, with a code from `F0001`: a field `silver` doesn't know or of the wrong type, a missing `name`, an entry with no `path`, or with a `source` or `uses` and no `name`, a name that isn't a package's, an empty directory, a directory that isn't one, a name in `uses` that no entry gives (`F0025`, which lists the names the entries do give, each with its line, so a name written differently from the one its file gives shows), a directory with a `path` alone that has no `silver.toml` and that no file above describes (`F0026`, which says what to write instead: inside the file's directory, to describe it here with a `name`; outside it, to give that directory a `silver.toml` of its own or to give the `path` of a package another file describes; and for a directory of another package's modules, that package's own directory), an entry with a `name`, `source` or `uses` at a directory with a `silver.toml` of its own (`F0037`, saying that file describes it, so here it's listed by `path` alone), or one package name at two directories (`F0028`). A described package outside the file's directory (`F0020`) is told that a package elsewhere has a `silver.toml` of its own and is listed by `path` alone, and one under another `silver.toml` (`F0024`) that it's listed by `path` alone if that file describes it, or moves out from under it. A mistake in the `silver.toml` of a package that's read only because another file lists it has a second line naming that file and the entry's line. A package with a file of its own whose directory is inside the directory of a package whose modules are its whole directory (no `source`, or `source = "."`), or holds it, is `F0035`, located at the entry that reaches it; the message says that giving that package a `source` directory below it avoids it.
- `version`, `git`, `branch`, `rev` and `tag` on an entry are `F0038`: remote packages aren't built. `test` on an entry has to be `true` or `false`. `test` at the top of a file isn't a field, since the file's own package is always tested from there.
- A file that still has `[paths]` or `[[part]]` is told, at that key, that `[[package]]` replaced it.
- With no `silver.toml` at or above the file, the command line is passed on as it is, with `--from-silver` added, so `silverc`'s package options, described in [Modules](language/modules.md#current-implementation), still reach the compiler when given there. What the compiler says then names no option: a file in no project that imports a package is told it uses only the standard library, and that a `silver.toml` at or above it naming a package of its own, with the package in `uses` and a `[[package]]` entry whose `path` is the package's directory, whose own `silver.toml` names it, gives it one; a file whose `module` line names no package is told a package is a directory with a `silver.toml` that names it.
- Inside a project, packages are described in `silver.toml`, and `--package`, `--uses` or `--project` given before the file is `F0036`, which says where each belongs in the package file. So are `--also` and `--skip`, since what's tested is decided by the `test` field of the `[[package]]` entries and by the path given, and the message says so. Outside a project all five are passed on.

What `silverc` is given:

- Each package's directory and uses, as `--package` and `--uses`; for the file's own package, the packages it describes, as `--project`, which with it are one project; and the file that describes each, as `--package-file`, so that what `silverc` reports about a package names that file and its `uses` rather than an option, and a starting file whose `module` line names no package is told the name its package and path give it. A package with a file of its own is given with its own `--project`, never in the lister's. The directories are given relative to where `silver` was started when they're inside it. `std` isn't given: `silverc` adds it.
- `--from-silver`, on every run, so that what `silverc` says about a package no package file describes names what to write in a `silver.toml` rather than an option. Run by hand, without it, `silverc`'s messages name its options.
- For a file or directory in a project, which packages' directories hold it, with `--scripts-in`: the deepest package whose directory holds the file, and for a directory, also each one whose directory is inside it. A package that only describes others is given too, so that a script there is told it uses only the standard library and belongs under the directory of a package it describes.
- With no file, the package started in, as `--program`, for `run` and `build`, and then the program's arguments after `--`, which is where `silverc` takes them with `--program`. After a file they follow it as given, and `silverc` drops a first `--` there by the same rule.
- For `test` over a directory, what [What `silver test` tests](#what-silver-test-tests) leaves out under it, as `--skip`: each directory with a `silver.toml` that isn't tested, the outermost only, and each described package whose entry says `test = false`. Each other place tested that walking the directory doesn't reach, as `--also`: a package outside opted in, or a package the file lists by its directory inside a project it doesn't otherwise name. The run is one call of `silverc`, so one report and one JSON document. A package tested is read and followed, with its dependencies, whether or not anything uses it, so a listed package nothing uses is given to `silverc` when it's tested. `--scripts-in` is given for every place tested.
- An entry of the starting file that says a package isn't tested, by `test = false` or by being outside and not opted in, leaves out that package's directory even when a wider place tested holds it, such as a package outside that's opted in, or a package listed with a file of its own that describes it: the more specific entry wins. A `--skip` that is, or holds, a path given to be tested is refused by `silverc`, as the two disagree.
- A project left out isn't mentioned in the report. With `--show-command`, one more line on stderr after the command line names the directories that a `silver.toml` names and the run leaves out, and why.

Commands with no file, and `run` or `build` with a directory:

- `run` and `build` start from the program of the package started in: the module that declares `main`, the root module included, or the one package it describes that's a program. A package listed with a file of its own is never among them. A library, or a package none of whose described packages is a program, is `L0014`, which says its tests are run with `silver test` and that a file with no `module` line is run by naming it. It says nothing about the packages the file lists, so a root whose only programs have files of their own gets no pointer to them. Several programs are `L0015`, which lists each with the file its `main` is in, and each described package with its directory: its `path` when `silver` gives the packages, and its directory of modules when `silverc` is run by hand. A package with a `main` of its own that describes programs lists itself too, as chosen by naming its file. A package, or a described package among the candidates, with more than one module that declares `main` is `L0016`, which lists the files and says to name the one to run; starting from a named file is unchanged.
- `silver run <directory>` and `silver build <directory>` take the package whose directory, its `silver.toml`'s or its `path`, is that directory; a `source` directory isn't one. A directory with a `silver.toml` of its own is its own project's, so this runs a package listed with a file of its own too. Another directory in a project is `F0034`, with no position, which lists the project's packages and their directories. After the directory, the program's arguments follow `--`, and a word there that isn't `--` is refused with the command that would pass it. A directory in no project is passed on as it is.
- `test` with no path is `test` over the directory of the package started in: its `silver.toml`'s directory, or a described package's `path`. So from a described package's directory only that package is tested, and from anywhere else in the file's directory what the file names. `test` over a directory tests that directory: what the file names under it is tested by the rule, and outside entries opted in only when it's the file's own directory.
- `test` over a directory in no project gives `--skip` for each directory under it with a `silver.toml`, the outermost only, so only the scripts outside them run.
- With no file and no `silver.toml` at or above the working directory, `run`, `build` and `test` are `F0033`.
- `silver build` with no `-o` writes the executable to the working directory, named after the file, or for a package's program after the last segment of the name of the package whose program it is, as `frontend` for `silver.frontend`, with `.exe` on Windows.

Scripts:

- A script under a package's directory that imports what the package doesn't use is told to list it in that package's `uses`. One under a program that imports the program is told a program can't be used, even by a file beside it. One under none of the project's packages is told it uses only the standard library, and that a script that needs a package belongs under that package's directory or under the directory of one that uses it; one under a package that only describes others is told that too, naming the packages it describes.
- A file whose `module` line names no package is told what the line has to be, by the package whose directory of modules holds it and its folders and file as the disk spells them; a folder or file name that can't be part of a module's name is named, to be renamed. Under a package with `source` but outside its modules, the file is told that a module of that package belongs under its `source` directory.
- `silver test` over a directory gives each script there the package it's under, or none.

Where the design leaves it open, `silver` takes the narrower reading:

- It refuses a `source` or a described package's `path` outside the directory it's taken from; a described package, or a package's `source`, in or under a directory with a `silver.toml` of its own below the file, since that file's package would hold its files; a described package at the file's own directory; a described package with the file's package's name or another's; two entries at one path; an entry with a `path` alone at the file's own directory or at a package the file describes; a name listed twice in `uses`; `std` in `uses`; and `uses` on a package that describes others and has no `source`.
- When any package of a file is reached, every package that file describes is read and followed and given to `silverc`, and every entry it lists with a `path` alone is read, to learn the name its file gives it, though only those something uses are followed. So a mistake in any entry, such as a directory that isn't there, stops every run that reaches the file, including one from a package elsewhere that uses a different package of it.
- A package with a file of its own inside the directory of the listing file's package, when that package's modules are its whole directory, is refused (`F0035`) whether or not anything uses it.
- Only the packages the nearest `silver.toml` describes can be started in, not the packages it lists with files of their own.
- A package listed under the directory of one of the file's packages is tested with it, as above, only when that package's modules are elsewhere, under `source`. Without `source`, one package's directory would be inside the other's, which `silver` refuses (`F0035`).
- A listed package's own `test = true` entries count only when `silver test` starts from that package's directory, not when it's reached from a file above it, so a run never leaves the starting file's directory tree except for that file's own opt-ins.
- An entry outside the directory opted in that's a package another file describes, by its directory, tests that package alone, not the rest of the project its file describes.
- Opting in a package outside tests its own project alone, but honours `test = false` on the packages its file describes.
- What a run leaves out that a `silver.toml` names is said only with `--show-command`, on stderr.
- With no path, `silver test` tests the package started in, while `silver test .` tests that one directory, so in a plain folder inside a package the two differ: the first tests the whole package, the second only that folder.
- Naming a package's `source` directory tests its modules, but not the scripts beside its `silver.toml`, which are outside that directory.
- A script under a package's directory has every module of that package read, to tell a library from a program, so a syntax error in any of them stops every script there, including one that imports nothing from the package. The error is reported once.
- When a directory has the name `silver build` would give the executable, as a described package's own directory can, it's refused and `-o` is asked for.
- Only `run` takes a program's arguments. After the file, or after `--`, `build` says a program is given them when it's run, and `test` that it takes one path; `silver test --` is refused, since tests take no arguments.
- `--` where the file would be always means there's no file, for `silverc` too, so a file whose name starts with `-` is named by a path, as `./-x.ag`.

Not built:

- Remote packages: `version`, `git`, `tag`, `branch` and `rev` are refused (`F0038`), and there's no `silver.lock`, cache or `silver update`.
- A script in no project, or under none of a project's packages, can't say it needs a package.
- A package can't be used only by tests, and the build can't name another prelude.
- A program is compiled whole, in one call of `silverc`, rather than a package at a time.
