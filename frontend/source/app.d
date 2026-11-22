import silver.frontend : exactArguments, run;

/// What follows a program's file is the program's, so druntime doesn't take `--DRT-` options from it.
extern (C) __gshared bool rt_cmdline_enabled = false;

int main(string[] args)
{
    return run(exactArguments(args));
}
