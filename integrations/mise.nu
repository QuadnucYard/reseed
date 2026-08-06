use ../lib/core.nu [command-exists info run-command warning]
use cargo_binstall.nu [cargo-binstall-reconcile cargo-binstall-restore cargo-binstall-update cargo-binstall-verify]

def mise-context [path: path]: nothing -> record {
  let name = ($path | path basename)
  let directory = ($path | path dirname | into string)
  if $name == "mise.toml" {
    return {directory: $directory environment: null}
  }

  let parsed = ($name | parse --regex '^mise\.(?<environment>[A-Za-z0-9_-]+)\.toml$')
  if ($parsed | is-empty) {
    error make {msg: $"Unsupported mise config name '($name)'; use mise.toml or mise.<environment>.toml"}
  }
  {directory: $directory environment: ($parsed | first | get environment)}
}

def mise-args [path: path args: list<string>]: nothing -> list<string> {
  let context = (mise-context $path)
  mut prefix = ["-C" $context.directory]
  if $context.environment != null {
    $prefix = ($prefix | append ["-E" $context.environment])
  }
  $prefix | append $args
}

export def mise-status [root: path config: record]: nothing -> record {
  let settings = $config.software.mise
  let configs = ($settings.configs? | default [])
  {
    tool: mise
    enabled: ($settings.enabled? | default false)
    applicable: true
    available: (command-exists mise)
    desired: ($configs | each {|item| {path: $item exists: (($root | path join $item) | path exists)} })
  }
}

export def mise-restore [root: path config: record --dry-run] {
  let settings = $config.software.mise
  if not ($settings.enabled? | default false) { return }
  if not (command-exists mise) and not $dry_run { error make {msg: "mise is required for the portable tools stage"} }
  for relative in ($settings.configs? | default []) {
    let path = ($root | path join $relative)
    run-command mise (mise-args $path ["install" "--yes"]) --dry-run=$dry_run | ignore
  }

  cargo-binstall-restore $root $config --dry-run=$dry_run

  let configs = ($settings.configs? | default [])
  let task_config = if ($configs | is-empty) { null } else { $root | path join ($configs | last) }
  for task in ($settings.restore_tasks? | default []) {
    if $task_config == null { error make {msg: $"Cannot run mise task '($task)' without a mise config"} }
    run-command mise (mise-args $task_config ["run" $task]) --dry-run=$dry_run | ignore
  }
}

export def mise-update [root: path config: record --dry-run] {
  let settings = $config.software.mise
  if not ($settings.enabled? | default false) or not ($settings.update? | default true) { return }
  if not (command-exists mise) and not $dry_run { warning "mise is unavailable; skipping portable tool updates"; return }
  for relative in ($settings.configs? | default []) {
    let path = ($root | path join $relative)
    run-command mise (mise-args $path ["upgrade" "--yes"]) --dry-run=$dry_run | ignore
  }
  cargo-binstall-update $root $config --dry-run=$dry_run
}

export def mise-reconcile [root: path config: record --dry-run]: nothing -> list<record> {
  let settings = $config.software.mise
  if not ($settings.enabled? | default false) { return [] }
  if not (command-exists mise) and not $dry_run { return [{tool: mise error: "mise is unavailable"}] }
  mut results = []
  for relative in ($settings.configs? | default []) {
    let path = ($root | path join $relative)
    let result = (run-command mise (mise-args $path ["outdated"]) --allow-failure --dry-run=$dry_run)
    $results = ($results | append {
      tool: mise
      config: $relative
      ok: ($result.exit_code == 0)
      outdated: ($result.stdout | str trim)
      error: ($result.stderr | str trim)
    })
  }
  let cargo = (cargo-binstall-reconcile $root $config --dry-run=$dry_run)
  if $cargo != null and ($cargo.applicable? | default false) { $results = ($results | append $cargo) }
  $results
}

export def mise-verify [root: path config: record]: nothing -> list<record> {
  let settings = $config.software.mise
  if not ($settings.enabled? | default false) { return [] }
  mut results = [{check: "mise executable" ok: (command-exists mise) detail: "portable tool manager"}]
  for relative in ($settings.configs? | default []) {
    let path = ($root | path join $relative)
    $results = ($results | append {check: $"mise config: ($relative)" ok: ($path | path exists) detail: ($path | into string)})
  }
  if (command-exists mise) {
    for relative in ($settings.configs? | default []) {
      let path = ($root | path join $relative)
      let missing = (run-command mise (mise-args $path ["ls" "--missing"]) --allow-failure)
      $results = ($results | append {
        check: $"mise tools installed: ($relative)"
        ok: (($missing.exit_code == 0) and ($missing.stdout | str trim | is-empty))
        detail: (if ($missing.stdout | str trim | is-empty) { "complete" } else { $missing.stdout | str trim })
      })
    }
  }
  $results = ($results | append (cargo-binstall-verify $root $config))
  $results
}
