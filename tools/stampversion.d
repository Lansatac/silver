/// Writes the version that `silver --version` and `silverc --version` print into the file named by the
/// first argument, from the SILVER_VERSION environment variable or else `git describe`, and leaves the
/// file alone when it already says that, so a build with nothing changed has nothing to recompile.
///
/// A `v0.1.0` tag gives `0.1.0`; commits after it `0.1.0-3-gabc1234`, and a modified tree adds `-dirty`.
/// With no tag at all it's `0.0.0-gabc1234`, and with no git history (a source archive) `0.0.0-dev`.
module stampversion;

import std.file : exists, mkdirRecurse, readText, write;
import std.path : absolutePath, buildPath, dirName;
import std.process : environment, execute;
import std.string : strip, startsWith;

string describe(string root)
{
    if (!exists(buildPath(root, ".git"))) return null;
    try
    {
        auto tagged = execute(["git", "-C", root, "describe", "--tags", "--match", "v[0-9]*", "--dirty"]);
        if (tagged.status == 0) return tagged.output.strip;
        auto commit = execute(["git", "-C", root, "describe", "--always", "--dirty", "--abbrev=7"]);
        if (commit.status == 0) return "0.0.0-g" ~ commit.output.strip;
    }
    catch (Exception) {}
    return null;
}

int main(string[] args)
{
    if (args.length != 2) return 2;
    auto root = absolutePath(buildPath(dirName(__FILE_FULL_PATH__), ".."));
    auto version_ = environment.get("SILVER_VERSION", "");
    if (version_.length == 0) version_ = describe(root);
    if (version_.length == 0) version_ = "0.0.0-dev";
    if (version_.startsWith("v")) version_ = version_[1 .. $];
    mkdirRecurse(dirName(absolutePath(args[1])));
    if (!exists(args[1]) || readText(args[1]) != version_) write(args[1], version_);
    return 0;
}
