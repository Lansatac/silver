/// Writes the version that `silver --version` and `silverc --version` print into the file named by the
/// first argument, for the repository whose root is the second, from the SILVER_VERSION environment
/// variable or else `git describe`, and leaves the file alone when it already says that, so a build
/// with nothing changed has nothing to recompile.
///
/// A `v0.1.0` tag gives `0.1.0`; commits after it `0.1.0-3-gabc1234`, and a modified tree adds `-dirty`.
/// With no `v*` tag it's `0.0.0-gabc1234`, and with no git history (a source archive) `0.0.0-dev`.
module app;

import std.file : exists, mkdirRecurse, readText, write;
import std.path : absolutePath, buildPath, dirName;
import std.process : environment, execute;
import std.string : startsWith, strip;

/// What `git describe` says of the repository at `root`, or null when there's no git history.
string describe(string root)
{
    if (!exists(buildPath(root, ".git"))) return null;
    try
    {
        auto tagged = execute(["git", "-C", root, "describe", "--tags", "--match", "v[0-9]*", "--dirty"]);
        if (tagged.status == 0) return tagged.output.strip;
        // Excluding every tag keeps another tag's name out of it.
        auto commit = execute(["git", "-C", root, "describe", "--always", "--dirty", "--abbrev=7", "--exclude=*"]);
        if (commit.status == 0) return "0.0.0-g" ~ commit.output.strip;
    }
    catch (Exception) {}
    return null;
}

int main(string[] args)
{
    if (args.length != 3) return 2;
    auto version_ = environment.get("SILVER_VERSION", "");
    if (version_.length == 0) version_ = describe(absolutePath(args[2]));
    if (version_.length == 0) version_ = "0.0.0-dev";
    if (version_.startsWith("v")) version_ = version_[1 .. $];
    mkdirRecurse(dirName(absolutePath(args[1])));
    if (!exists(args[1]) || readText(args[1]) != version_) write(args[1], version_);
    return 0;
}
