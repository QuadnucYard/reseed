#requires -Version 5.1

<#
.SYNOPSIS
    Bootstrap the Reseed engine on Windows: installs the bootstrap-contract
    tools (Git, chezmoi, Nushell, mise) through WinGet when missing, and
    checks them for available upgrades.

.DESCRIPTION
    When a bootstrap tool is outdated the script prompts before upgrading
    (interactive runs only). -UpdateTools applies upgrades without prompting;
    -NoUpdateTools skips the upgrade check entirely. WinGet itself is a Store
    app without a CLI self-update, so only the contract tools are checked.

.PARAMETER StateRepository
    Private state repository URL; cloned when the state root is uninitialized,
    and used to refresh (fast-forward) an already-initialized state root before
    restore. Mutually exclusive with StateSource.

.PARAMETER StateSource
    Immutable downloaded private-state source (a Git checkout, bundle archive,
    or raw snapshot). When given, the source is imported into the state root
    and restore runs from the recovered state instead of a repository.
    Mutually exclusive with StateRepository.

.PARAMETER StateRoot
    Private state root; defaults to RESEED_STATE_ROOT or ~\.local\share\reseed.

.PARAMETER Profiles
    Comma-separated profile names; defaults to "personal".

.PARAMETER Scope
    WinGet install/upgrade scope; defaults to "machine".

.PARAMETER NoRestore
    Stop after bootstrapping and state initialization.

.PARAMETER Offline
    Require the bootstrap tools to already exist; skips installs and checks.

.PARAMETER DryRun
    Report outdated tools without upgrading, and run the restore as a dry run.

.PARAMETER UpdateTools
    Upgrade outdated bootstrap tools without prompting.

.PARAMETER NoUpdateTools
    Skip the bootstrap-tool upgrade check entirely.
#>
[CmdletBinding()]
param(
    [Alias("Repository")]
    [string]$StateRepository,
    [string]$StateSource,
    [string]$StateRoot,
    [string]$Profiles = "personal",
    [ValidateSet("user", "machine")]
    [string]$Scope = "machine",
    [switch]$NoRestore,
    [switch]$Offline,
    [switch]$DryRun,
    [switch]$UpdateTools,
    [switch]$NoUpdateTools
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

if ($UpdateTools -and $NoUpdateTools) {
    throw "-UpdateTools and -NoUpdateTools are mutually exclusive."
}
if (-not [string]::IsNullOrWhiteSpace($StateSource) -and -not [string]::IsNullOrWhiteSpace($StateRepository)) {
    throw "-StateSource and -StateRepository are mutually exclusive."
}

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
    command appears on PATH afterwards. Required packages (the bootstrap
    contract) stop the bootstrap on failure; optional packages only warn.
#>
function Install-WinGetPackage {
    param(
        [string]$Id,
        [string]$Command,
        [switch]$Required
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
            if ($Required) {
                throw "WinGet failed to install $Id (exit $LASTEXITCODE). $Id is required for the bootstrap to continue."
            }
            Write-Warning "WinGet failed to install $Id (exit $LASTEXITCODE); continuing without it."
            return
        }
    }
    Refresh-Path
    if (-not (Test-Command $Command)) {
        if ($Required) {
            throw "$Id was installed but $Command is not visible on PATH. Open a new terminal and rerun bootstrap.ps1."
        }
        Write-Warning "$Id was installed but $Command is not visible on PATH; continuing without it."
    }
}

<#
.SYNOPSIS
    The bootstrap contract: WinGet identifiers, their commands, and whether
    the package is required. Git, chezmoi, and Nushell are the recovery
    critical tools (the offline recovery trio), so their install failure
    stops the bootstrap; mise is software-only and failure only warns.
#>
function Get-BootstrapContract {
    return @(
        @{ Id = "Git.Git"; Command = "git.exe"; Required = $true }
        @{ Id = "twpayne.chezmoi"; Command = "chezmoi.exe"; Required = $true }
        @{ Id = "Nushell.Nushell"; Command = "nu.exe"; Required = $true }
        @{ Id = "jdx.mise"; Command = "mise.exe"; Required = $false }
    )
}

<#
.SYNOPSIS
    Return the available upgrade for a WinGet package, or $null.
.DESCRIPTION
    Queries "winget list --upgrade-available" and parses the result table.
    Failures (unparsable output, stale source metadata) degrade to $null so
    the check never blocks the bootstrap.
#>
function Get-WinGetUpgradeVersion {
    param([string]$Id)
    $lines = @(& winget.exe list --id $Id --exact --upgrade-available 2>$null)
    $inTable = $false
    foreach ($line in $lines) {
        if ($line -match '^-{5,}') {
            $inTable = $true
            continue
        }
        if ($inTable -and $line.Trim() -and $line -match [regex]::Escape($Id)) {
            $fields = @($line -split '\s+' | Where-Object { $_ })
            if ($fields.Count -ge 5) {
                return [pscustomobject]@{ Installed = $fields[2]; Available = $fields[3] }
            }
        }
    }
    return $null
}

<#
.SYNOPSIS
    Upgrade a package with WinGet to its latest version.
.DESCRIPTION
    Uses the requested scope first and retries with WinGet's default scope
    when that fails. Upgrade failures only warn: the installed version stays
    in place and the bootstrap continues.
#>
function Update-WinGetPackage {
    param(
        [string]$Id,
        [string]$Command
    )
    Write-Step "upgrading $Id"
    $arguments = @(
        "upgrade", "--id", $Id, "--exact", "--scope", $Scope,
        "--accept-source-agreements", "--accept-package-agreements",
        "--disable-interactivity"
    )
    & winget.exe @arguments
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "The requested $Scope scope was unavailable for $Id; retrying with its default scope."
        $arguments = @(
            "upgrade", "--id", $Id, "--exact",
            "--accept-source-agreements", "--accept-package-agreements",
            "--disable-interactivity"
        )
        & winget.exe @arguments
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "WinGet failed to upgrade $Id (exit $LASTEXITCODE); keeping the installed version."
            return
        }
    }
    Refresh-Path
    if (-not (Test-Command $Command)) {
        throw "$Id was upgraded but $Command is not visible on PATH. Open a new terminal and rerun bootstrap.ps1."
    }
}

<#
.SYNOPSIS
    True when the run is interactive: a user session with unredirected stdin.
#>
function Test-Interactive {
    return [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
}

<#
.SYNOPSIS
    Check the bootstrap-contract tools for available WinGet upgrades.
.DESCRIPTION
    Prompts before upgrading on interactive runs; -UpdateTools upgrades
    without prompting; non-interactive runs and -DryRun only report.
#>
function Update-OutdatedBootstrapTools {
    if ($NoUpdateTools) { return }
    if (-not (Test-Command "winget.exe")) {
        Write-Step "winget is unavailable; skipping the outdated check"
        return
    }
    Write-Step "checking for outdated bootstrap tools"
    $outdated = @()
    foreach ($tool in Get-BootstrapContract) {
        $version = Get-WinGetUpgradeVersion -Id $tool.Id
        if ($null -ne $version) {
            $outdated += [pscustomobject]@{
                Id = $tool.Id
                Command = $tool.Command
                Installed = $version.Installed
                Available = $version.Available
            }
        }
    }
    if ($outdated.Count -eq 0) {
        Write-Step "bootstrap tools are up to date"
        return
    }
    Write-Step "outdated bootstrap tools:"
    foreach ($tool in $outdated) {
        Write-Host "  $($tool.Id) $($tool.Installed) -> $($tool.Available)"
    }
    if ($DryRun) {
        Write-Step "dry run: leaving outdated bootstrap tools unchanged"
        return
    }
    $upgrade = $false
    if ($UpdateTools) {
        $upgrade = $true
    }
    elseif (Test-Interactive) {
        $reply = Read-Host "Upgrade these bootstrap tools now? [y/N]"
        $upgrade = $reply.Trim().ToLowerInvariant() -match '^(y|yes)$'
        if (-not $upgrade) { Write-Step "skipping upgrade" }
    }
    else {
        Write-Step "non-interactive run: leaving outdated bootstrap tools unchanged"
        return
    }
    if ($upgrade) {
        foreach ($tool in $outdated) {
            Update-WinGetPackage -Id $tool.Id -Command $tool.Command
        }
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
    Otherwise they are installed through WinGet. A -StateSource path is local
    and compatible with offline recovery; only -StateRepository is rejected.
#>
function Ensure-BootstrapTools {
    if ($Offline) {
        if (-not [string]::IsNullOrWhiteSpace($StateRepository)) {
            throw "-Offline cannot be combined with -StateRepository. Use an extracted bundle state directory or -StateSource."
        }
        foreach ($command in @("git.exe", "chezmoi.exe", "nu.exe")) {
            if (-not (Test-Command $command)) {
                throw "Offline recovery requires $command in tools\windows-<arch> or on PATH."
            }
        }
    }
    else {
        foreach ($tool in Get-BootstrapContract) {
            Install-WinGetPackage -Id $tool.Id -Command $tool.Command -Required:$tool.Required
        }
        Update-OutdatedBootstrapTools
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
    Fast-forward the already-initialized private state from the provided
    repository, so recovery always restores from the supplied source. The sync
    logic lives in "nu sync-state": it refuses mismatched remotes, leaves a
    dirty or diverged working tree alone, and fails when the repository cannot
    be reached.
#>
function Sync-StateRepository {
    param(
        [string]$Entrypoint,
        [string]$Root,
        [string]$Repository
    )
    Write-Step "syncing private state: $(Format-RedactedUrl $Repository)"
    & nu.exe $Entrypoint sync-state --state-root $Root --repository $Repository
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to sync private state (exit $LASTEXITCODE)."
    }
}

<#
.SYNOPSIS
    Clone the private state repository when the state root is uninitialized.
.DESCRIPTION
    Refuses a nonempty directory without the .reseed-state sentinel, reads the
    remote before cloning so a wrong URL fails early, and clones the remote's
    default branch (from its symbolic HEAD) rather than assuming main. An
    already-initialized root is instead synced from the provided repository so
    a stale local copy repairs itself.
#>
function Initialize-StateRepository {
    param(
        [string]$Entrypoint,
        [string]$Root,
        [string]$Repository
    )
    if ([string]::IsNullOrWhiteSpace($Repository)) { return }
    $sentinel = Join-Path $Root ".reseed-state"
    if (Test-Path -LiteralPath $sentinel -PathType Leaf) {
        Sync-StateRepository -Entrypoint $Entrypoint -Root $Root -Repository $Repository
        return
    }
    if (Test-Path -LiteralPath $Root) {
        $entries = @(Get-ChildItem -Force -LiteralPath $Root)
        if ($entries.Count -gt 0) {
            throw "Refusing nonempty state directory without .reseed-state: $Root"
        }
    }
    $sym = @(& git.exe ls-remote --symref $Repository HEAD 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw "Cannot read the private state repository: $(Format-RedactedUrl $Repository)"
    }
    $defaultBranch = ($sym | Where-Object { $_ -match '^ref:' } | ForEach-Object {
        ($_ -replace '^ref: refs/heads/(\S+).*', '$1')
    } | Where-Object { $_ } | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($defaultBranch)) { $defaultBranch = "main" }
    $hasRef = @($sym | Where-Object { $_ -match "refs/heads/$defaultBranch$" })
    if ($hasRef.Count -gt 0) {
        Write-Step "cloning private state"
        & git.exe clone --branch $defaultBranch --single-branch $Repository $Root
        if ($LASTEXITCODE -ne 0) { throw "Failed to clone private state (exit $LASTEXITCODE)." }
    }
    elseif ($sym.Count -gt 0) {
        throw "The private state repository has content but no $defaultBranch branch."
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
.DESCRIPTION
    When -StateSource was given, the restore command receives --state-source so
    the downloaded source is validated and imported atomically before the
    recovery plan runs.
#>
function Invoke-Restore {
    param(
        [string]$Entrypoint,
        [string]$Root,
        [string]$StateSource = ""
    )
    Write-Step "engine: $PSScriptRoot"
    Write-Step "private state: $Root"
    if ($NoRestore) {
        Write-Step "bootstrap completed; run: nu `"$Entrypoint`" plan --state-root `"$Root`" --profiles $Profiles"
        return
    }
    $arguments = @($entrypoint, "restore", "--state-root", $Root, "--profiles", $Profiles)
    if (-not [string]::IsNullOrWhiteSpace($StateSource)) {
        $arguments += @("--state-source", $StateSource)
    }
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
if (-not [string]::IsNullOrWhiteSpace($StateSource)) {
    # A downloaded source drives recovery directly: import it and restore.
    Invoke-Restore -Entrypoint (Join-Path $engineRoot "reseed.nu") -Root $resolvedRoot -StateSource $StateSource
} else {
    Initialize-StateRepository -Entrypoint (Join-Path $engineRoot "reseed.nu") -Root $resolvedRoot -Repository $StateRepository
    Initialize-PrivateState -Entrypoint (Join-Path $engineRoot "reseed.nu") -Root $resolvedRoot -Repository $StateRepository
    Invoke-Restore -Entrypoint (Join-Path $engineRoot "reseed.nu") -Root $resolvedRoot
}
