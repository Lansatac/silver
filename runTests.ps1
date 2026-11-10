# Runs every package's tests, then the root's. Extra arguments go to each `dub test`.
$packages = 'silver:ast', 'silver:syntax', 'silver:loader', 'silver:sema', 'silver:core', 'silver:interpreter', 'silver:codegen', 'silver:conformance', 'silver'
$failed = @()

Push-Location $PSScriptRoot
try
{
    foreach ($package in $packages)
    {
        Write-Host "=== $package"
        dub test $package @args
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
