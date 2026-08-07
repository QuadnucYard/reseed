use ../lib/prelude.nu *
use bootstrap.nu [bootstrap-winget-ids]

# Package identifiers extracted from a WinGet export file (JSON with a
# Sources/Packages structure).
export def winget-manifest-ids [
  path: path # WinGet export file.
]: nothing -> list<string> {
  if not ($path | path exists) { return [] }
  let manifest = (open $path)
  $manifest.Sources?
    | default []
    | each {|source| $source.Packages? | default [] }
    | flatten
    | each {|package| $package.PackageIdentifier? }
    | compact
    | uniq
    | sort
}

# WinGet identifiers from a manifest, excluding the bootstrap-contract tools
# the engine installs itself.
export def native-winget-manifest-ids [
  path: path # WinGet export file.
]: nothing -> list<string> {
  winget-manifest-ids $path | where {|id| $id not-in (bootstrap-winget-ids) }
}

# Availability and desired-manifest health for the WinGet integration.
export def winget-status [
  root: path # Private state root.
  config: record # Loaded configuration.
]: nothing -> record {
  let enabled = ($config.software.winget.enabled? | default false)
  let manifests = ($config.software.winget.manifests? | default [])
  {
    tool: winget
    enabled: $enabled
    applicable: ((detect-os) == "windows")
    available: (command-exists winget)
    desired: ($manifests | each {|item| {path: $item exists: (($root | path join $item) | path exists)} })
  }
}

# Import every configured WinGet manifest, ignoring unavailable packages and
# version mismatches so a partial import still completes.
export def winget-restore [
  root: path # Private state root.
  config: record # Loaded configuration.
  --dry-run # Show the imports without running them.
] {
  let settings = $config.software.winget
  if not ($settings.enabled? | default false) or ((detect-os) != "windows") { return }
  if not (command-exists winget) and not $dry_run { error make {msg: "WinGet is required for the Windows package stage"} }
  for manifest in ($settings.manifests? | default []) {
    let path = ($root | path join $manifest)
    run-command winget [
      "import" "--import-file" ($path | into string) "--ignore-unavailable"
      "--ignore-versions" "--accept-source-agreements" "--accept-package-agreements"
      "--disable-interactivity"
    ] --dry-run=$dry_run | ignore
  }
}

# Upgrade every curated package in the configured manifests. A nonzero exit
# is tolerated when WinGet reports nothing to upgrade or the package is
# absent from the system.
export def winget-update [
  root: path # Private state root.
  config: record # Loaded configuration.
  --dry-run # Show the upgrades without running them.
] {
  let settings = $config.software.winget
  if not ($settings.enabled? | default false) or not ($settings.update? | default true) or ((detect-os) != "windows") { return }
  if not (command-exists winget) and not $dry_run { warning "WinGet is unavailable; skipping Windows package updates"; return }
  let ids = ($settings.manifests? | default [] | each {|manifest| native-winget-manifest-ids ($root | path join $manifest) } | flatten | uniq | sort)
  for id in $ids {
    let result = (run-command winget [
      "upgrade" "--id" $id "--exact" "--accept-source-agreements"
      "--accept-package-agreements" "--disable-interactivity"
    ] --dry-run=$dry_run --allow-failure --capture)
    if ($result.exit_code != 0) and not (($result.stdout | str lowercase) =~ 'no applicable upgrade|no available upgrade|no installed package') {
      warning $"WinGet could not update ($id): ($result.stderr | str trim)"
    }
  }
}

# Remove the bootstrap-contract package identifiers from a WinGet export
# file in place, keeping the curated manifest free of engine-owned tools.
def filter-bootstrap-winget-ids [
  path: path # WinGet export file to rewrite.
] {
  let ignored = (bootstrap-winget-ids)
  let manifest = (open $path)
  let sources = ($manifest.Sources? | default [] | each {|source|
    let packages = ($source.Packages? | default [] | where {|package| ($package.PackageIdentifier? | default "") not-in $ignored })
    $source | upsert Packages $packages
  })
  $manifest | upsert Sources $sources | to json --indent 2 | save --force $path
}

# Export the installed packages to a WinGet file, optionally filtering out
# the bootstrap tools. Export failures degrade to a warning because WinGet
# can exit nonzero even when the file is usable.
def export-winget [
  path: path # Destination export file.
  --exclude-bootstrap # Filter engine-owned packages from the export.
  --dry-run # Show the export without running it.
]: nothing -> bool {
  if $dry_run {
    run-command winget ["export" "--output" ($path | into string) "--accept-source-agreements"] --dry-run | ignore
    return true
  }
  mkdir ($path | path dirname)
  let result = (run-command winget ["export" "--output" ($path | into string) "--accept-source-agreements"] --allow-failure --capture)
  if $result.exit_code != 0 {
    warning $"WinGet export failed: ($result.stderr | str trim)"
    false
  } else {
    if $exclude_bootstrap { filter-bootstrap-winget-ids $path }
    true
  }
}

# Capture the WinGet inventory. With --refresh-manifests the single configured
# manifest is replaced by the live export; otherwise the export is written as
# an observation under the disposable state directory.
export def winget-backup [
  root: path # Private state root.
  config: record # Loaded configuration.
  --refresh-manifests # Replace the curated manifest with the live export.
  --dry-run # Show the export without running it.
] {
  let settings = $config.software.winget
  if not ($settings.enabled? | default false) or ((detect-os) != "windows") or not (command-exists winget) { return }
  let refresh = $refresh_manifests or ($settings.export_on_backup? | default false)
  let target = if $refresh {
    let manifests = ($settings.manifests? | default [])
    if ($manifests | length) != 1 {
      warning "WinGet refresh requires exactly one target manifest; writing an observation instead"
      observation-dir $config | path join "winget.json"
    } else {
      $root | path join ($manifests | first)
    }
  } else {
    observation-dir $config | path join "winget.json"
  }
  export-winget $target --exclude-bootstrap=$refresh --dry-run=$dry_run | ignore
  if not $refresh { info $"WinGet observation: ($target)" }
}

# Compare the curated manifests with a fresh export, report-only.
export def winget-reconcile [
  root: path # Private state root.
  config: record # Loaded configuration.
  --dry-run # Skip the live export.
]: nothing -> record {
  let settings = $config.software.winget
  if not ($settings.enabled? | default false) or ((detect-os) != "windows") {
    return {tool: winget applicable: false desired_only: [] observed_only: []}
  }
  if not (command-exists winget) {
    return {tool: winget applicable: true error: "winget is unavailable" desired_only: [] observed_only: []}
  }
  let observed = (observation-dir $config | path join "winget.json")
  if not (export-winget $observed --dry-run=$dry_run) or $dry_run {
    return {tool: winget applicable: true observation: $observed desired_only: [] observed_only: []}
  }
  let desired_ids = ($settings.manifests? | default [] | each {|manifest| native-winget-manifest-ids ($root | path join $manifest) } | flatten | uniq | sort)
  let observed_ids = (native-winget-manifest-ids $observed)
  {
    tool: winget
    applicable: true
    observation: $observed
    desired_only: ($desired_ids | where {|id| $id not-in $observed_ids })
    observed_only: ($observed_ids | where {|id| $id not-in $desired_ids })
  }
}

# Verification checks for WinGet: executable presence, manifest health, and
# that every curated package is installed.
export def winget-verify [
  root: path # Private state root.
  config: record # Loaded configuration.
]: nothing -> list<record> {
  let settings = $config.software.winget
  if not ($settings.enabled? | default false) or ((detect-os) != "windows") { return [] }
  mut results = [{check: "winget executable" ok: (command-exists winget) detail: "required on Windows"}]
  for manifest in ($settings.manifests? | default []) {
    let path = ($root | path join $manifest)
    let ids = (native-winget-manifest-ids $path)
    $results = ($results | append {check: $"winget manifest: ($manifest)" ok: ($path | path exists) detail: $"($ids | length) curated package IDs"})
    if (command-exists winget) {
      for id in $ids {
        let installed = (try {
          run-command winget ["list" "--id" $id "--exact" "--accept-source-agreements" "--disable-interactivity"] --allow-failure --capture
        } catch {|error| {exit_code: 1 stdout: "" stderr: ($error.msg? | default "failed to start winget")} })
        $results = ($results | append {
          check: $"winget installed: ($id)"
          ok: ($installed.exit_code == 0)
          detail: (if $installed.exit_code == 0 { "installed" } else { ($installed.stdout + $installed.stderr | str trim) })
        })
      }
    }
  }
  $results
}
