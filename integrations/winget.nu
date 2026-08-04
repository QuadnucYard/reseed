use ../lib/core.nu [command-exists detect-os info run-command warning]
use ../lib/state.nu [observation-dir]

export def winget-manifest-ids [path: path]: nothing -> list<string> {
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

export def winget-status [root: path config: record]: nothing -> record {
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

export def winget-restore [root: path config: record --dry-run] {
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

export def winget-update [root: path config: record --dry-run] {
  let settings = $config.software.winget
  if not ($settings.enabled? | default false) or not ($settings.update? | default true) or ((detect-os) != "windows") { return }
  if not (command-exists winget) and not $dry_run { warning "WinGet is unavailable; skipping Windows package updates"; return }
  let ids = ($settings.manifests? | default [] | each {|manifest| winget-manifest-ids ($root | path join $manifest) } | flatten | uniq | sort)
  for id in $ids {
    let result = (run-command winget [
      "upgrade" "--id" $id "--exact" "--accept-source-agreements"
      "--accept-package-agreements" "--disable-interactivity"
    ] --dry-run=$dry_run --allow-failure)
    if ($result.exit_code != 0) and not (($result.stdout | str downcase) =~ 'no applicable upgrade|no available upgrade|no installed package') {
      warning $"WinGet could not update ($id): ($result.stderr | str trim)"
    }
  }
}

def export-winget [path: path --dry-run]: nothing -> bool {
  if $dry_run {
    run-command winget ["export" "--output" ($path | into string) "--accept-source-agreements"] --dry-run | ignore
    return true
  }
  mkdir ($path | path dirname)
  let result = (run-command winget ["export" "--output" ($path | into string) "--accept-source-agreements"] --allow-failure)
  if $result.exit_code != 0 {
    warning $"WinGet export failed: ($result.stderr | str trim)"
    false
  } else { true }
}

export def winget-backup [root: path config: record --refresh-manifests --dry-run] {
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
  export-winget $target --dry-run=$dry_run | ignore
  if not $refresh { info $"WinGet observation: ($target)" }
}

export def winget-reconcile [root: path config: record --dry-run]: nothing -> record {
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
  let desired_ids = ($settings.manifests? | default [] | each {|manifest| winget-manifest-ids ($root | path join $manifest) } | flatten | uniq | sort)
  let observed_ids = (winget-manifest-ids $observed)
  {
    tool: winget
    applicable: true
    observation: $observed
    desired_only: ($desired_ids | where {|id| $id not-in $observed_ids })
    observed_only: ($observed_ids | where {|id| $id not-in $desired_ids })
  }
}

export def winget-verify [root: path config: record]: nothing -> list<record> {
  let settings = $config.software.winget
  if not ($settings.enabled? | default false) or ((detect-os) != "windows") { return [] }
  mut results = [{check: "winget executable" ok: (command-exists winget) detail: "required on Windows"}]
  for manifest in ($settings.manifests? | default []) {
    let path = ($root | path join $manifest)
    let ids = (winget-manifest-ids $path)
    $results = ($results | append {check: $"winget manifest: ($manifest)" ok: (($path | path exists) and ($ids | is-not-empty)) detail: $"($ids | length) package IDs"})
    if (command-exists winget) {
      for id in $ids {
        let installed = (try {
          run-command winget ["list" "--id" $id "--exact" "--accept-source-agreements" "--disable-interactivity"] --allow-failure
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
