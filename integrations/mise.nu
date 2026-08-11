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

# Environment passed to the shell generator so it uses the selected source
# and shell config rather than rediscovering either from the user home.
export def mise-shell-task-environment [
  root: path # Private state root.
  config: record # Loaded configuration.
]: nothing -> record {
  let shell_config = (mise-shell-config $root $config | into string)
  {
    RESEED_STATE_ROOT: ($root | path expand --no-symlink | into string)
    RESEED_MISE_CONFIG_FILE: $shell_config
    MISE_GLOBAL_CONFIG_FILE: $shell_config
  }
}

# Config file used to run tasks. Environment-specific configs are ordered last
# and mise applies their native environment selection through mise-args.
def mise-task-config [
  root: path # Private state root.
  settings: record # Mise configuration section.
]: nothing -> any {
  let configs = ($settings.configs? | default [])
  if ($configs | is-empty) { null } else { $root | path join ($configs | last) }
}

# Shell task selection with compatibility for state repositories created before
# shell_task was split from general restore_tasks.
export def mise-shell-task [settings: record]: nothing -> string {
  let explicit = ($settings.shell_task? | default null)
  if $explicit != null {
    $explicit
  } else if "reseed:shells" in ($settings.restore_tasks? | default []) {
    "reseed:shells"
  } else {
    ""
  }
}

# Restore the portable-tools stage: install mise tools, prepare the managed
# bin directory, then restore the cargo-binstall, uv, and Node manager globals,
# and finally run general restore tasks. Shell configuration runs after
# chezmoi so generated profile loaders cannot be overwritten by apply.
# Package-manager install failures only warn; the returned count lets the
# workflow fail with a summary at the end.
export def mise-restore [
  root: path # Private state root.
  config: record # Loaded configuration.
  --dry-run # Show the installs without running them.
]: nothing -> int {
  let settings = $config.software.mise
  if not ($settings.enabled? | default false) { return 0 }
  if not (command-exists mise) and not $dry_run { error make {msg: "mise is required for the portable tools stage"} }
  mut failures = 0
  for command in (mise-install-plan $root $config) {
    let result = (run-or-warn mise $command.args --dry-run=$dry_run --label=$"mise install ($command.config)")
    if $result.exit_code != 0 { $failures += 1 }
  }

  prepare-managed-bin --dry-run=$dry_run

  $failures += (cargo-binstall-restore $root $config --dry-run=$dry_run)
  $failures += (uv-restore $root $config --dry-run=$dry_run)
  for manager in [pnpm yarn bun] {
    $failures += (node-manager-restore $root $config $manager --dry-run=$dry_run)
  }

  # Restore tasks run against the last configured config, matching mise's
  # own "last config wins" scoping for ad-hoc commands. They are not package
  # installs, so their failures still stop the stage.
  let task_config = (mise-task-config $root $settings)
  let shell_task = (mise-shell-task $settings)
  for task in (($settings.restore_tasks? | default []) | where {|task| $task != $shell_task }) {
    if $task_config == null { error make {msg: $"Cannot run mise task '($task)' without a mise config"} }
    run-command mise (mise-args $task_config ["run" $task]) --dry-run=$dry_run | ignore
  }
  $failures
}

# Generate shell adapters and install their profile loaders after chezmoi has
# applied the desired home state. The task name is explicit so future shell
# implementations remain separate from general restore hooks.
export def mise-configure-shells [
  root: path # Private state root.
  config: record # Loaded configuration.
  --dry-run # Show generation without changing the home directory.
] {
  let settings = $config.software.mise
  if not ($settings.enabled? | default false) { return }
  let task = (mise-shell-task $settings)
  if ($task | str trim | is-empty) { return }
  if not (command-exists mise) and not $dry_run {
    error make {msg: "mise is required to configure interactive shells"}
  }
  let task_config = (mise-task-config $root $settings)
  if $task_config == null { error make {msg: $"Cannot run mise shell task '($task)' without a mise config"} }
  let environment = (mise-shell-task-environment $root $config)
  if $task == "reseed:shells" {
    # The stock generator is state-repo-owned; invoke it with an absolute path
    # so resolution never depends on the mise task working directory.
    let generator = ($root | path join "scripts" "configure-shells.nu")
    if not ($generator | path exists) {
      error make {msg: $"The ('reseed:shells') shell task requires its generator, which is missing: ($generator). Re-run 'reseed init' or 'reseed restore' to seed engine-owned files into the state repository"}
    }
    run-command mise (mise-exec-args $task_config "nu" ["--no-config-file" ($generator | into string)]) --environment=$environment --dry-run=$dry_run | ignore
    return
  }
  run-command mise (mise-args $task_config ["run" $task]) --environment=$environment --dry-run=$dry_run | ignore
}

# Upgrade every mise config and refresh the managed-tools lifecycle.
# Upgrade failures warn and are counted so the workflow can exit nonzero.
export def mise-update [
  root: path # Private state root.
  config: record # Loaded configuration.
  --dry-run # Show the upgrades without running them.
]: nothing -> int {
  let settings = $config.software.mise
  if not ($settings.enabled? | default false) or not ($settings.update? | default true) { return 0 }
  if not (command-exists mise) and not $dry_run { warning "mise is unavailable; skipping portable tool updates"; return 0 }
  mut failures = 0
  for relative in ($settings.configs? | default []) {
    let path = ($root | path join $relative)
    let result = (run-or-warn mise (mise-args $path ["upgrade" "--yes"]) --dry-run=$dry_run --label=$"mise upgrade ($relative)")
    if $result.exit_code != 0 { $failures += 1 }
  }
  prepare-managed-bin --dry-run=$dry_run
  $failures += (cargo-binstall-update $root $config --dry-run=$dry_run)
  $failures += (uv-update $root $config --dry-run=$dry_run)
  for manager in [pnpm yarn bun] {
    $failures += (node-manager-update $root $config $manager --dry-run=$dry_run)
  }
  $failures
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
    let result = (run-command mise (mise-args $path ["outdated"]) --allow-failure --dry-run=$dry_run --capture)
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
      let missing = (run-command mise (mise-args $path ["ls" "--missing"]) --allow-failure --capture)
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
