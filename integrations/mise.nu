use ../lib/prelude.nu *
use managers/cargo_binstall.nu [cargo-binstall-reconcile cargo-binstall-restore cargo-binstall-update cargo-binstall-verify]
use managers/uv.nu [uv-reconcile uv-restore uv-update uv-verify]
use managers/node/node_manager.nu [node-manager-reconcile node-manager-restore node-manager-update node-manager-verify]

# Availability and desired-config health for the mise integration.
export def mise-status [
  root: path # Private state root.
  config: record # Loaded configuration.
]: nothing -> record {
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

# Ordered mise install commands: for each config, first the host runtime of
# every backend-qualified tool (backends need their runtime present), then
# the complete install. Fails when a backend's runtime is not declared.
export def mise-install-plan [
  root: path # Private state root.
  config: record # Loaded configuration.
]: nothing -> list<record> {
  let settings = $config.software.mise
  mut commands = []
  for relative in ($settings.configs? | default []) {
    let path = ($root | path join $relative)
    let missing = (mise-missing-backend-dependencies $path)
    if ($missing | is-not-empty) {
      let first = ($missing | first)
      error make {msg: $"Mise config '($relative)' uses the '($first.backend)' backend but does not declare '($first.tool)' in [tools]; add ($first.tool) = \"latest\" before restoring"}
    }
    for dependency in (mise-backend-dependencies $path) {
      $commands = ($commands | append {
        config: $relative
        kind: dependency
        tool: $dependency.tool
        args: (mise-args $path ["install" "--yes" $dependency.tool])
      })
    }
    $commands = ($commands | append {
      config: $relative
      kind: complete
      tool: null
      args: (mise-args $path ["install" "--yes"])
    })
  }
  $commands
}

# Restore the portable-tools stage: install mise tools, prepare the managed
# bin directory, then restore the cargo-binstall, uv, and Node manager
# globals, and finally run any configured restore tasks.
export def mise-restore [
  root: path # Private state root.
  config: record # Loaded configuration.
  --dry-run # Show the installs without running them.
] {
  let settings = $config.software.mise
  if not ($settings.enabled? | default false) { return }
  if not (command-exists mise) and not $dry_run { error make {msg: "mise is required for the portable tools stage"} }
  for command in (mise-install-plan $root $config) {
    run-command mise $command.args --dry-run=$dry_run | ignore
  }

  prepare-managed-bin --dry-run=$dry_run

  cargo-binstall-restore $root $config --dry-run=$dry_run
  uv-restore $root $config --dry-run=$dry_run
  for manager in [pnpm yarn bun] {
    node-manager-restore $root $config $manager --dry-run=$dry_run
  }

  # Restore tasks run against the last configured config, matching mise's
  # own "last config wins" scoping for ad-hoc commands.
  let configs = ($settings.configs? | default [])
  let task_config = if ($configs | is-empty) { null } else { $root | path join ($configs | last) }
  for task in ($settings.restore_tasks? | default []) {
    if $task_config == null { error make {msg: $"Cannot run mise task '($task)' without a mise config"} }
    run-command mise (mise-args $task_config ["run" $task]) --dry-run=$dry_run | ignore
  }
}

# Upgrade every mise config and refresh the managed-tools lifecycle.
export def mise-update [
  root: path # Private state root.
  config: record # Loaded configuration.
  --dry-run # Show the upgrades without running them.
] {
  let settings = $config.software.mise
  if not ($settings.enabled? | default false) or not ($settings.update? | default true) { return }
  if not (command-exists mise) and not $dry_run { warning "mise is unavailable; skipping portable tool updates"; return }
  for relative in ($settings.configs? | default []) {
    let path = ($root | path join $relative)
    run-command mise (mise-args $path ["upgrade" "--yes"]) --dry-run=$dry_run | ignore
  }
  prepare-managed-bin --dry-run=$dry_run
  cargo-binstall-update $root $config --dry-run=$dry_run
  uv-update $root $config --dry-run=$dry_run
  for manager in [pnpm yarn bun] {
    node-manager-update $root $config $manager --dry-run=$dry_run
  }
}

# Reconcile report for the whole portable-tools layer: mise outdated status
# plus the cargo-binstall, uv, and Node manager comparisons.
export def mise-reconcile [
  root: path # Private state root.
  config: record # Loaded configuration.
  --dry-run # Skip live inventories.
]: nothing -> list<record> {
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
  let uv = (uv-reconcile $root $config --dry-run=$dry_run)
  if $uv != null and ($uv.applicable? | default false) { $results = ($results | append $uv) }
  for manager in [pnpm yarn bun] {
    let result = (node-manager-reconcile $root $config $manager --dry-run=$dry_run)
    if $result != null and ($result.applicable? | default false) { $results = ($results | append $result) }
  }
  $results
}

# Verification checks for the whole portable-tools layer.
export def mise-verify [
  root: path # Private state root.
  config: record # Loaded configuration.
]: nothing -> list<record> {
  let settings = $config.software.mise
  if not ($settings.enabled? | default false) { return [] }
  mut results = [{check: "mise executable" ok: (command-exists mise) detail: "portable tool manager"}]
  for relative in ($settings.configs? | default []) {
    let path = ($root | path join $relative)
    $results = ($results | append {check: $"mise config: ($relative)" ok: ($path | path exists) detail: ($path | into string)})
  }
  # "mise ls --missing" lists declared tools that are not installed yet;
  # empty output (with exit 0) means the config is fully satisfied.
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
  $results = ($results | append (uv-verify $root $config))
  for manager in [pnpm yarn bun] {
    $results = ($results | append (node-manager-verify $root $config $manager))
  }
  $results
}
