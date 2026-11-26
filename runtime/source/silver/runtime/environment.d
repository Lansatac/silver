/// Reading an environment variable, under `lang.process`'s `environment`. The interpreter compiles this
/// module too, so both backends give the same answers. It uses only druntime and Phobos.
///
/// A variable that isn't set, one whose value isn't UTF-8 (on Windows, whose values are UTF-16, one with
/// an unpaired surrogate) and a name no system could hold are all the same answer, `None`. On Windows the
/// system compares names without regard to case, so `path` finds `Path`; elsewhere case matters.
module silver.runtime.environment;

/// The value of the variable `name`, or null when there is none to give. An empty value is a value:
/// it's not null.
string environmentValue(const(char)[] name) nothrow
{
    import std.utf : validate;

    // An empty name, one with `=` (which a system uses to split a name from its value, and on Windows
    // starts the names of its hidden per-drive variables), and one with a NUL can't be a variable's.
    if (name.length == 0) return null;
    foreach (c; name)
    {
        if (c == '=' || c == '\0') return null;
    }
    try
    {
        version (Windows)
        {
            import core.sys.windows.winbase : GetEnvironmentVariableW;
            import std.utf : toUTF16z, toUTF8;

            import core.sys.windows.winbase : GetLastError, SetLastError;
            import core.sys.windows.winerror : ERROR_ENVVAR_NOT_FOUND;

            auto wideName = toUTF16z(name);
            // The size can change between the two calls, so ask again until it fits.
            wchar[] buffer = new wchar[256];
            while (true)
            {
                // Zero is also an empty value, which only the last error tells from no variable.
                SetLastError(0);
                auto length = GetEnvironmentVariableW(wideName, buffer.ptr, cast(uint) buffer.length);
                if (length == 0)
                {
                    return GetLastError() == ERROR_ENVVAR_NOT_FOUND ? null : "";
                }
                if (length < buffer.length)
                {
                    // Converting would replace an unpaired surrogate rather than refuse it.
                    validate(buffer[0 .. length]);
                    return buffer[0 .. length].toUTF8;
                }
                buffer = new wchar[length];
            }
        }
        else
        {
            import core.stdc.stdlib : getenv;
            import std.string : fromStringz, toStringz;

            auto found = getenv(name.toStringz);
            if (found is null) return null;
            auto value = found.fromStringz.idup;
            validate(value);
            return value;
        }
    }
    catch (Exception)
    {
        return null;
    }
}

@("a name that isn't set, an empty one and one with `=` or a NUL are none")
unittest
{
    assert(environmentValue("SILVER_SURELY_NOT_SET_IN_ANY_ENVIRONMENT") is null);
    assert(environmentValue("") is null);
    assert(environmentValue("A=B") is null);
    assert(environmentValue("PA\0TH") is null);
}

@("a set variable's value is its text, and an empty value is not none")
unittest
{
    import std.process : environment;

    environment["SILVER_ENVIRONMENT_TEST"] = "héllo 世界";
    scope (exit) environment.remove("SILVER_ENVIRONMENT_TEST");
    assert(environmentValue("SILVER_ENVIRONMENT_TEST") == "héllo 世界");

    environment["SILVER_ENVIRONMENT_TEST"] = "";
    auto empty = environmentValue("SILVER_ENVIRONMENT_TEST");
    assert(empty !is null && empty.length == 0);

    environment.remove("SILVER_ENVIRONMENT_TEST");
    assert(environmentValue("SILVER_ENVIRONMENT_TEST") is null);
}

@("a value longer than the first buffer is all there")
unittest
{
    import std.process : environment;
    import std.array : replicate;

    auto long_ = "x".replicate(5000);
    environment["SILVER_ENVIRONMENT_LONG"] = long_;
    scope (exit) environment.remove("SILVER_ENVIRONMENT_LONG");
    assert(environmentValue("SILVER_ENVIRONMENT_LONG") == long_);
}

version (Windows)
{
    @("names are matched without regard to case, and a value with an unpaired surrogate is none")
    unittest
    {
        import core.sys.windows.winbase : SetEnvironmentVariableW;

        assert(SetEnvironmentVariableW("Silver_Environment_Case"w.ptr, "value"w.ptr));
        scope (exit) SetEnvironmentVariableW("Silver_Environment_Case"w.ptr, null);
        assert(environmentValue("SILVER_ENVIRONMENT_CASE") == "value");
        assert(environmentValue("silver_environment_case") == "value");

        wchar[2] broken = [cast(wchar) 0xD800, 0];
        assert(SetEnvironmentVariableW("Silver_Environment_Broken"w.ptr, broken.ptr));
        scope (exit) SetEnvironmentVariableW("Silver_Environment_Broken"w.ptr, null);
        assert(environmentValue("Silver_Environment_Broken") is null);
    }
}
else
{
    @("a value that isn't UTF-8 is none, and a name's case matters")
    unittest
    {
        import core.sys.posix.stdlib : setenv, unsetenv;

        assert(setenv("SILVER_ENVIRONMENT_BYTES", "caf\xE9", 1) == 0);
        scope (exit) unsetenv("SILVER_ENVIRONMENT_BYTES");
        assert(environmentValue("SILVER_ENVIRONMENT_BYTES") is null);
        assert(setenv("SILVER_ENVIRONMENT_BYTES", "caf\xC3\xA9", 1) == 0);
        assert(environmentValue("SILVER_ENVIRONMENT_BYTES") == "café");
        assert(environmentValue("silver_environment_bytes") is null);
    }
}
