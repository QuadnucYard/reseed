#requires -Version 5.1

[CmdletBinding()]
param(
    [Alias("Repository")]
    [string]$StateRepository,
    [string]$StateRoot,
    [string]$Profiles = "personal",
    [ValidateSet("user", "machine")]
    [string]$Scope = "machine",
    [switch]$NoRestore,
    [switch]$Offline,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

<#
.SYNOPSIS
    Print a step banner in the reseed style.
#>
function Write-Step {
    param([string]$Message)
    Write-Host "reseed: $Message" -ForegroundColor Cyan
}

<#
.SYNOPSIS
    Rebuild the process PATH from the registry so newly installed tools are
    visible without opening a new terminal.
#>
function Refresh-Path {
    $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $user = [Environment]::GetEnvironmentVariable("Path", "User")
    # Join treats a missing registry value as empty, which is fine: at most
    # one empty segment appears at the start or middle of the result.
    $env:Path = @($machine, $user) -join [IO.Path]::PathSeparator
}

<#
.SYNOPSIS
    True when an executable is available on PATH.
#>
function Test-Command {
    param([string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

<#
.SYNOPSIS
    Redact the userinfo of a URL so credentials never leak into errors.
.DESCRIPTION
    Matches "scheme://anything-without-/@-or-space@" and replaces the
    userinfo (including a possible password) with ***.
#>
function Format-RedactedUrl {
    param([string]$Value)
    if ($Value -match '^([a-z][a-z0-9+.-]*://)[^@/\s]+@') {
        return $Value -replace '^([a-z][a-z0-9+.-]*://)[^@/\s]+@', '${1}***@'
    }
    return $Value
}

<#
.SYNOPSIS
    Install a package with WinGet unless its command is already available.
.DESCRIPTION
    Installs with the requested scope first; when the package does not
    support that scope, retries with WinGet's default scope. Verifies the
    command appears on PATH afterwards.
#>
function Install-WinGetPackage {
    param(
        [string]$Id,
        [string]$Command
    )

    if (Test-Command $Command) {
        Write-Step "$Command is already available"
        return
    }
    if (-not (Test-Command "winget.exe")) {
        throw "WinGet is required. Install App Installer or provide portable tools beside this bootstrap."
    }

    Write-Step "installing $Id"
    $arguments = @(
        "install", "--id", $Id, "--exact", "--scope", $Scope,
        "--accept-source-agreements", "--accept-package-agreements",
        "--disable-interactivity"
    )
    & winget.exe @arguments
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "The requested $Scope scope was unavailable for $Id; retrying with its default scope."
        $arguments = @(
            "install", "--id", $Id, "--exact",
            "--accept-source-agreements", "--accept-package-agreements",
            "--disable-interactivity"
        )
        & winget.exe @arguments
        if ($LASTEXITCODE -ne 0) {
            throw "WinGet failed to install $Id (exit $LASTEXITCODE)."
        }
    }
    Refresh-Path
    if (-not (Test-Command $Command)) {
        throw "$Id was installed but $Command is not visible on PATH. Open a new terminal and rerun bootstrap.ps1."
    }
}

<#
.SYNOPSIS
    Prepend portable bootstrap tools (tools\windows-<arch>) to the process
    PATH when the directory ships beside this script.
#>
function Add-PortableToolsPath {
    if (-not $PSScriptRoot) {
        return
    }
    $architecture = if ([Environment]::Is64BitOperatingSystem) { "amd64" } else { "x86" }
    $portable = Join-Path $PSScriptRoot "tools\windows-$architecture"
    if (Test-Path -LiteralPath $portable -PathType Container) {
        # Prepending shadows any duplicate tools already on PATH so the
        # bundle's pinned versions win.
        $env:Path = "$portable$([IO.Path]::PathSeparator)$env:Path"
        Write-Step "using portable tools from $portable"
    }
}

<#
.SYNOPSIS
    Make sure every tool of the bootstrap contract is available.
.DESCRIPTION
    In offline mode the tools must already exist (portable or on PATH).
    Otherwise they are installed through WinGet.
#>
function Ensure-BootstrapTools {
    if ($Offline) {
        if (-not [string]::IsNullOrWhiteSpace($StateRepository)) {
            throw "-Offline cannot be combined with -StateRepository. Use an extracted bundle state directory."
        }
        foreach ($command in @("git.exe", "chezmoi.exe", "nu.exe")) {
            if (-not (Test-Command $command)) {
                throw "Offline recovery requires $command in tools\windows-<arch> or on PATH."
            }
        }
    }
    else {
        Install-WinGetPackage -Id "Git.Git" -Command "git.exe"
        Install-WinGetPackage -Id "twpayne.chezmoi" -Command "chezmoi.exe"
        Install-WinGetPackage -Id "Nushell.Nushell" -Command "nu.exe"
        Install-WinGetPackage -Id "jdx.mise" -Command "mise.exe"
    }
}

<#
.SYNOPSIS
    Verify the engine directory and return its absolute path.
#>
function Assert-EngineRoot {
    if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        throw "Run bootstrap.ps1 from the Reseed engine directory."
    }
    $entrypoint = Join-Path $PSScriptRoot "reseed.nu"
    if (-not (Test-Path -LiteralPath $entrypoint -PathType Leaf)) {
        throw "The engine directory does not contain reseed.nu: $PSScriptRoot"
    }
    return $PSScriptRoot
}

<#
.SYNOPSIS
    Resolve the private state root from -StateRoot, RESEED_STATE_ROOT, or the
    default under the home directory.
#>
function Resolve-StateRoot {
    if (-not [string]::IsNullOrWhiteSpace($StateRoot)) {
        return [IO.Path]::GetFullPath($StateRoot)
    }
    if (-not [string]::IsNullOrWhiteSpace($env:RESEED_STATE_ROOT)) {
        return [IO.Path]::GetFullPath($env:RESEED_STATE_ROOT)
    }
    return Join-Path $HOME ".local\share\reseed"
}

<#
.SYNOPSIS
    Clone the private state repository when the state root is uninitialized.
.DESCRIPTION
    Refuses a nonempty directory without the .reseed-state sentinel, reads the
    remote before cloning so a wrong URL fails early, and only clones when the
    remote has a main branch.
#>
function Initialize-StateRepository {
    param(
        [string]$Root,
        [string]$Repository
    )
    $sentinel = Join-Path $Root ".reseed-state"
    if ([string]::IsNullOrWhiteSpace($Repository) -or (Test-Path -LiteralPath $sentinel -PathType Leaf)) {
        return
    }
    if (Test-Path -LiteralPath $Root) {
        $entries = @(Get-ChildItem -Force -LiteralPath $Root)
        if ($entries.Count -gt 0) {
            throw "Refusing nonempty state directory without .reseed-state: $Root"
        }
    }
    $refs = @(& git.exe ls-remote $Repository 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw "Cannot read the private state repository: $(Format-RedactedUrl $Repository)"
    }
    $mainRef = @($refs | Where-Object { $_ -match "refs/heads/main$" })
    if ($mainRef.Count -gt 0) {
        Write-Step "cloning private state"
        & git.exe clone --branch main --single-branch $Repository $Root
        if ($LASTEXITCODE -ne 0) { throw "Failed to clone private state (exit $LASTEXITCODE)." }
    }
    elseif ($refs.Count -gt 0) {
        throw "The private state repository has content but no main branch."
    }
}

<#
.SYNOPSIS
    Run "nu init" to create or validate the private state, wiring up the
    remote URL when one was given.
#>
function Initialize-PrivateState {
    param(
        [string]$Entrypoint,
        [string]$Root,
        [string]$Repository
    )
    $sentinel = Join-Path $Root ".reseed-state"
    if (-not (Test-Path -LiteralPath $sentinel -PathType Leaf)) {
        $initArguments = @($entrypoint, "init", "--state-root", $Root)
        if (-not [string]::IsNullOrWhiteSpace($Repository)) {
            $initArguments += @("--remote-url", $Repository)
        }
        & nu.exe @initArguments
        if ($LASTEXITCODE -ne 0) { throw "Failed to initialize private state (exit $LASTEXITCODE)." }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Repository)) {
        & nu.exe $entrypoint init --state-root $Root --remote-url $Repository
        if ($LASTEXITCODE -ne 0) { throw "Private state remote validation failed (exit $LASTEXITCODE)." }
    }
}

<#
.SYNOPSIS
    Run the restore (or report how to plan it) once the state is ready.
#>
function Invoke-Restore {
    param(
        [string]$Entrypoint,
        [string]$Root
    )
    Write-Step "engine: $PSScriptRoot"
    Write-Step "private state: $Root"
    if ($NoRestore) {
        Write-Step "bootstrap completed; run: nu `"$Entrypoint`" plan --state-root `"$Root`" --profiles $Profiles"
        return
    }
    $arguments = @($entrypoint, "restore", "--state-root", $Root, "--profiles", $Profiles)
    if ($DryRun) { $arguments += "--dry-run" }
    if ($Offline) { $arguments += "--skip-software" }
    & nu.exe @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Reseed restore failed (exit $LASTEXITCODE)."
    }
}

Add-PortableToolsPath
Ensure-BootstrapTools
$engineRoot = Assert-EngineRoot
$resolvedRoot = Resolve-StateRoot
Initialize-StateRepository -Root $resolvedRoot -Repository $StateRepository
Initialize-PrivateState -Entrypoint (Join-Path $engineRoot "reseed.nu") -Root $resolvedRoot -Repository $StateRepository
Invoke-Restore -Entrypoint (Join-Path $engineRoot "reseed.nu") -Root $resolvedRoot
