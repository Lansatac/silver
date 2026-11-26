# Runs every package's tests, then the root's. Extra arguments go to each package's test command.
# Conformance runs each compiled program optimized as well; SILVER_CONFORMANCE_UNOPTIMIZED=1 skips that.
# $env:SILVER_CONFORMANCE_CASES = "glob,glob" limits conformance to the cases whose name (or directory/name) matches.
# Packages are named relative to this directory (`:sema`, not `silver:sema`): dub can resolve a
# qualified name to another checkout of the package, such as a git worktree.
#
# Builds and tests with redub from Jason's fork (github.com/Lansatac/redub, branch test-root), which
# generates the dub_test_root that silver.testrunner needs and leaves dub.selections.json's entries
# alone: $env:SILVER_REDUB, else ~\redub\build\redub.exe, else `redub` on the PATH (which in the dev
# container is the fork, built into its image). Without one, dub does the same work more slowly.
# $env:SILVER_REDUB_PARALLEL is passed to redub as --parallel (auto, full, leaves or no): each dmd that
# compiles against sema takes gigabytes, and several at once can need more memory than a machine has.
$packages = ':ast', ':syntax', ':loader', ':sema', ':core', ':interpreter', ':codegen', ':testing', ':conformance', ':frontend', 'root'
$failed = @()

$own = Join-Path $HOME 'redub\build\redub.exe'
$onPath = Get-Command redub -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$tool = if ($env:SILVER_REDUB) { $env:SILVER_REDUB }
    elseif (Test-Path $own -PathType Leaf) { $own }
    elseif ($onPath) { $onPath.Source }
    else { $null }
if (-not $tool -or -not (Test-Path $tool -PathType Leaf))
{
    Write-Host "note: redub wasn't found, so dub builds and tests. See the comment at the top of $PSCommandPath."
    $tool = 'dub'
}
$options = @()
if ($tool -ne 'dub' -and $env:SILVER_REDUB_PARALLEL) { $options = @("--parallel=$env:SILVER_REDUB_PARALLEL") }

Push-Location $PSScriptRoot
try
{
    # The front end's end-to-end tests run the built silver and silverc.
    Write-Host "=== build"
    & $tool build @options
    if ($LASTEXITCODE -ne 0) { $failed += 'build' }
    foreach ($package in $packages)
    {
        Write-Host "=== $package"
        if ($package -eq 'root') { & $tool test @options @args } else { & $tool test $package @options @args }
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
