use ../lib/core.nu [command-exists detect-os info run-command warning]
use ../lib/state.nu [observation-dir]

export def brewfile-items [path: path]: nothing -> list<string> {
  if not ($path | path exists) { return [] }
  open --raw $path
    | lines
    | each {|line| $line | str trim }
    | where {|line| ($line =~ '^(brew|cask|tap|mas|vscode)\s+"') }
    | each {|line| $line | str replace --regex '\s*#.*$' '' }
    | uniq
    | sort
}

export def homebrew-status [root: path config: record]: nothing -> record {
  let settings = $config.software.homebrew
  let manifests = ($settings.manifests? | default [])
  {
    tool: homebrew
    enabled: ($settings.enabled? | default false)
    applicable: ((detect-os) == "macos")
    available: (command-exists brew)
    desired: ($manifests | each {|item| {path: $item exists: (($root | path join $item) | path exists)} })
  }
}

export def homebrew-restore [root: path config: record --dry-run] {
  let settings = $config.software.homebrew
  if not ($settings.enabled? | default false) or ((detect-os) != "macos") { return }
  if not (command-exists brew) and not $dry_run { error make {msg: "Homebrew is required for the macOS package stage"} }
  for manifest in ($settings.manifests? | default []) {
    let path = ($root | path join $manifest)
    run-command brew ["bundle" "install" $"--file=($path)"] --dry-run=$dry_run | ignore
  }
}

export def homebrew-update [root: path config: record --dry-run] {
  let settings = $config.software.homebrew
  if not ($settings.enabled? | default false) or not ($settings.update? | default true) or ((detect-os) != "macos") { return }
  if not (command-exists brew) { warning "Homebrew is unavailable; skipping macOS package updates"; return }
  run-command brew ["update"] --dry-run=$dry_run | ignore
  for manifest in ($settings.manifests? | default []) {
    let path = ($root | path join $manifest)
    run-command brew ["bundle" "install" $"--file=($path)"] --dry-run=$dry_run | ignore
    for kind in [brews casks] {
      let listed = (run-command brew ["bundle" "list" $"--file=($path)" $"--($kind)"] --allow-failure --dry-run=$dry_run)
      if ($listed.exit_code == 0) and not $dry_run {
        let names = ($listed.stdout | lines | each {|line| $line | str trim } | compact)
        if ($names | is-not-empty) {
          let args = if $kind == "casks" { ["upgrade" "--cask"] | append $names } else { ["upgrade"] | append $names }
          let upgraded = (run-command brew $args --allow-failure)
          if $upgraded.exit_code != 0 { warning $"Some Homebrew ($kind) updates failed: ($upgraded.stderr | str trim)" }
        }
      }
    }
  }
}

def export-brewfile [path: path --dry-run]: nothing -> bool {
  if $dry_run {
    run-command brew ["bundle" "dump" $"--file=($path)" "--force"] --dry-run | ignore
    return true
  }
  mkdir ($path | path dirname)
  let result = (run-command brew ["bundle" "dump" $"--file=($path)" "--force"] --allow-failure)
  if $result.exit_code != 0 { warning $"Brewfile export failed: ($result.stderr | str trim)"; false } else { true }
}

export def homebrew-backup [root: path config: record --refresh-manifests --dry-run] {
  let settings = $config.software.homebrew
  if not ($settings.enabled? | default false) or ((detect-os) != "macos") or not (command-exists brew) { return }
  let refresh = $refresh_manifests or ($settings.export_on_backup? | default false)
  let target = if $refresh and (($settings.manifests? | default [] | length) == 1) {
    $root | path join ($settings.manifests | first)
  } else {
    if $refresh { warning "Homebrew refresh requires exactly one target Brewfile; writing an observation instead" }
    observation-dir $config | path join "Brewfile"
  }
  export-brewfile $target --dry-run=$dry_run | ignore
  if not $refresh { info $"Homebrew observation: ($target)" }
}

export def homebrew-reconcile [root: path config: record --dry-run]: nothing -> record {
  let settings = $config.software.homebrew
  if not ($settings.enabled? | default false) or ((detect-os) != "macos") {
    return {tool: homebrew applicable: false desired_only: [] observed_only: []}
  }
  if not (command-exists brew) {
    return {tool: homebrew applicable: true error: "brew is unavailable" desired_only: [] observed_only: []}
  }
  let observed = (observation-dir $config | path join "Brewfile")
  if not (export-brewfile $observed --dry-run=$dry_run) or $dry_run {
    return {tool: homebrew applicable: true observation: $observed desired_only: [] observed_only: []}
  }
  let desired = ($settings.manifests? | default [] | each {|manifest| brewfile-items ($root | path join $manifest) } | flatten | uniq | sort)
  let current = (brewfile-items $observed)
  {
    tool: homebrew
    applicable: true
    observation: $observed
    desired_only: ($desired | where {|item| $item not-in $current })
    observed_only: ($current | where {|item| $item not-in $desired })
  }
}

export def homebrew-verify [root: path config: record]: nothing -> list<record> {
  let settings = $config.software.homebrew
  if not ($settings.enabled? | default false) or ((detect-os) != "macos") { return [] }
  mut results = [{check: "homebrew executable" ok: (command-exists brew) detail: "required on macOS"}]
  for manifest in ($settings.manifests? | default []) {
    let path = ($root | path join $manifest)
    $results = ($results | append {check: $"Brewfile: ($manifest)" ok: ($path | path exists) detail: $"((brewfile-items $path | length)) entries"})
    if (command-exists brew) and ($path | path exists) {
      let checked = (try {
        run-command brew ["bundle" "check" $"--file=($path)"] --allow-failure
      } catch {|error| {exit_code: 1 stdout: "" stderr: ($error.msg? | default "failed to start brew")} })
      $results = ($results | append {
        check: $"Homebrew packages installed: ($manifest)"
        ok: ($checked.exit_code == 0)
        detail: (if $checked.exit_code == 0 { "complete" } else { ($checked.stdout + $checked.stderr | str trim) })
      })
    }
  }
  $results
}
