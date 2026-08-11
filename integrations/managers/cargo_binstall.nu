use ../../lib/prelude.nu *

# cargo-binstall settings from the configuration.
def settings [
  config: record # Loaded configuration.
]: nothing -> record {
  manager-settings $config cargo_binstall
}

# Specifier strings for every configured Cargo crate, validated against the
# binstall manifest schema.
export def cargo-binstall-packages [
  root: path # Private state root.
  config: record # Loaded configuration.
]: nothing -> list<string> {
  let configured = (settings $config)
  mut packages = []
  for relative in ($configured.manifests? | default []) {
    let path = ($root | path join $relative)
    if not ($path | path exists) {
      error make {msg: $"Missing cargo-binstall manifest: ($relative)"}
    }
    let manifest = (open $path)
    if ($manifest.schema? | default 0) != 1 {
      error make {msg: $"Unsupported cargo-binstall manifest schema: ($relative)"}
    }
    let listed = ($manifest.packages? | default [])
    if not (($listed | describe) | str starts-with "list") or not ($listed | all {|package| ($package | describe) == "string" }) {
      error make {msg: $"Cargo-binstall manifest packages must be a list: ($relative)"}
    }
    $packages = ($packages | append $listed)
  }
  $packages | uniq | sort
}

# cargo-binstall arguments; --force makes update reinstall over the existing
# binaries instead of skipping them.
export def cargo-binstall-args [
  install_root: path # Root whose bin directory receives installed commands.
  packages: list<string> # Crates to install.
  --update # Reinstall even when already installed.
]: nothing -> list<string> {
  mut args = ["--no-confirm" "--disable-telemetry" "--root" ($install_root | into string)]
  if $update { $args = ($args | append "--force") }
  $args | append $packages
}

# Run cargo-binstall through mise exec with the shared managed-tools
# environment. A failed install warns and returns 1 so the workflow can fail
# with a summary at the end.
def run-binstall [
  root: path # Private state root.
  config: record # Loaded configuration.
  packages: list<string> # Crates to install.
  --update # Reinstall over existing binaries.
  --dry-run # Show the command without running it.
]: nothing -> int {
  let install_root = (managed-bin-dir | path dirname)
  let result = (run-mise-managed $root $config "cargo-binstall" (cargo-binstall-args $install_root $packages --update=$update) "mise is required for the configured Cargo packages" --dry-run=$dry_run --allow-failure)
  if $result.exit_code != 0 {
    warning $"cargo-binstall failed to install Cargo packages with exit code ($result.exit_code); continuing"
    return 1
  }
  0
}

# Install every configured Cargo crate.
export def cargo-binstall-restore [
  root: path # Private state root.
  config: record # Loaded configuration.
  --dry-run # Show the installs without running them.
]: nothing -> int {
  let configured = (settings $config)
  if not ($configured.enabled? | default false) { return 0 }
  let packages = (cargo-binstall-packages $root $config)
  if ($packages | is-empty) { return 0 }
  run-binstall $root $config $packages --dry-run=$dry_run
}

# Upgrade every configured Cargo crate.
export def cargo-binstall-update [
  root: path # Private state root.
  config: record # Loaded configuration.
  --dry-run # Show the upgrades without running them.
]: nothing -> int {
  let configured = (settings $config)
  if not ($configured.enabled? | default false) or not ($configured.update? | default true) { return 0 }
  let packages = (cargo-binstall-packages $root $config)
  if ($packages | is-empty) { return 0 }
  if not $dry_run and not (command-exists mise) {
    warning "mise is unavailable; skipping Cargo binary updates"
    return 0
  }
  run-binstall $root $config $packages --update --dry-run=$dry_run
}

# Installed crate names from "cargo install --list" output, or
# {available: false} with a reason when the inventory cannot be produced.
def installed-cargo-packages [
  root: path # Private state root.
  config: record # Loaded configuration.
]: nothing -> record {
  if not (command-exists mise) {
    return {available: false packages: [] detail: "mise is unavailable"}
  }
  let result = (try {
    run-mise-managed $root $config "cargo" ["install" "--list" "--root" (managed-bin-dir | path dirname | into string)] "mise is required for the configured Cargo packages" --allow-failure --capture
  } catch {|error|
    {
      exit_code: 127
      stdout: ""
      stderr: ($error.msg? | default ($error | to nuon))
    }
  })
  if $result.exit_code != 0 {
    return {available: false packages: [] detail: ($result.stderr | str trim)}
  }
  let packages = ($result.stdout
    | lines
    | each {|line|
      let parsed = ($line | parse --regex '^(?<name>[A-Za-z0-9][A-Za-z0-9_-]*) v')
      if ($parsed | is-empty) { null } else { $parsed | first | get name }
    }
    | compact
    | uniq
    | sort)
  {available: true packages: $packages detail: "cargo install inventory"}
}

# Compare desired crates with the installed inventory, report-only.
export def cargo-binstall-reconcile [
  root: path # Private state root.
  config: record # Loaded configuration.
  --dry-run # Skip the live inventory.
]: nothing -> record {
  let configured = (settings $config)
  if not ($configured.enabled? | default false) {
    return {tool: cargo-binstall applicable: false desired_only: [] observed_only: []}
  }
  let desired = (cargo-binstall-packages $root $config)
  if $dry_run {
    return {tool: cargo-binstall applicable: true desired_only: [] observed_only: [] detail: "dry run"}
  }
  let installed = (installed-cargo-packages $root $config)
  if not $installed.available {
    return {tool: cargo-binstall applicable: true error: $installed.detail desired_only: $desired observed_only: []}
  }
  {
    tool: cargo-binstall
    applicable: true
    desired_only: ($desired | where {|package| $package not-in $installed.packages})
    observed_only: ($installed.packages | where {|package| $package not-in $desired})
  }
}

# Verification checks for cargo-binstall: executable presence and that every
# configured crate is installed.
export def cargo-binstall-verify [
  root: path # Private state root.
  config: record # Loaded configuration.
]: nothing -> list<record> {
  let configured = (settings $config)
  if not ($configured.enabled? | default false) { return [] }
  let packages = (cargo-binstall-packages $root $config)
  let executable = (try {
    run-mise-managed $root $config "cargo-binstall" ["--version"] "mise is required for the configured Cargo packages" --allow-failure --capture
  } catch {|error|
    {exit_code: 127 stdout: "" stderr: ($error.msg? | default "failed to start mise")}
  })
  mut results = [{
    check: "cargo-binstall executable"
    ok: ($executable.exit_code == 0)
    detail: "required for configured Cargo binaries"
  }]
  let installed = (installed-cargo-packages $root $config)
  let missing = if $installed.available {
    $packages | where {|package| $package not-in $installed.packages}
  } else {
    $packages
  }
  $results | append {
    check: "cargo-binstall packages"
    ok: ($missing | is-empty)
    detail: (if ($missing | is-empty) { "all configured crates installed" } else { $"missing: ($missing | str join ', ')" })
  }
}
