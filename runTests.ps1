# Runs every package's tests, then the root's. Extra arguments go to each `dub test`.
# Conformance runs each compiled program optimized as well; SILVER_CONFORMANCE_UNOPTIMIZED=1 skips that.
# Packages are named relative to this directory (`:sema`, not `silver:sema`): dub can resolve a
# qualified name to another checkout of the package, such as a git worktree.
$packages = ':ast', ':syntax', ':loader', ':sema', ':core', ':interpreter', ':codegen', ':testing', ':conformance', 'root'
$failed = @()

Push-Location $PSScriptRoot
try
{
    foreach ($package in $packages)
    {
        Write-Host "=== $package"
        if ($package -eq 'root') { dub test @args } else { dub test $package @args }
        if ($LASTEXITCODE -ne 0) { $failed += $package }
    }
}
finally
{
    Pop-Location
}

Write-Host
if ($failed.Count -eq 0)
{
    Write-Host "All $($packages.Count) packages passed."
}
else
{
    Write-Host "Failed: $($failed -join ', ')"
    exit 1
}
