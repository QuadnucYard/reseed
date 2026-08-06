use ../lib/core.nu [command-exists run-command warning]

def settings [config: record]: nothing -> record {
  $config.software.mise.cargo_binstall? | default {}
}

export def cargo-binstall-packages [root: path config: record]: nothing -> list<string> {
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

def binstall-args [packages: list<string> --update]: nothing -> list<string> {
  mut args = ["--no-confirm" "--disable-telemetry"]
  if $update { $args = ($args | append "--force") }
  $args | append $packages
}

def run-binstall [packages: list<string> --update --dry-run] {
  if not $dry_run and not (command-exists cargo-binstall) {
    error make {msg: "cargo-binstall is required for the configured Cargo packages; add cargo:cargo-binstall to mise.toml"}
  }
  run-command cargo-binstall (binstall-args $packages --update=$update) --dry-run=$dry_run | ignore
}

export def cargo-binstall-restore [root: path config: record --dry-run] {
  let configured = (settings $config)
  if not ($configured.enabled? | default false) { return }
  let packages = (cargo-binstall-packages $root $config)
  if ($packages | is-empty) { return }
  run-binstall $packages --dry-run=$dry_run
}

export def cargo-binstall-update [root: path config: record --dry-run] {
  let configured = (settings $config)
  if not ($configured.enabled? | default false) or not ($configured.update? | default true) { return }
  let packages = (cargo-binstall-packages $root $config)
  if ($packages | is-empty) { return }
  if not $dry_run and not (command-exists cargo-binstall) {
    warning "cargo-binstall is unavailable; skipping Cargo binary updates"
    return
  }
  run-binstall $packages --update --dry-run=$dry_run
}

def installed-cargo-packages []: nothing -> record {
  if not (command-exists cargo) {
    return {available: false packages: [] detail: "cargo is unavailable"}
  }
  let result = (try {
    run-command cargo ["install" "--list"] --allow-failure
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

export def cargo-binstall-reconcile [root: path config: record --dry-run]: nothing -> record {
  let configured = (settings $config)
  if not ($configured.enabled? | default false) {
    return {tool: cargo-binstall applicable: false desired_only: [] observed_only: []}
  }
  let desired = (cargo-binstall-packages $root $config)
  if $dry_run {
    return {tool: cargo-binstall applicable: true desired_only: [] observed_only: [] detail: "dry run"}
  }
  let installed = (installed-cargo-packages)
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

export def cargo-binstall-verify [root: path config: record]: nothing -> list<record> {
  let configured = (settings $config)
  if not ($configured.enabled? | default false) { return [] }
  let packages = (cargo-binstall-packages $root $config)
  mut results = [{
    check: "cargo-binstall executable"
    ok: (command-exists cargo-binstall)
    detail: "required for configured Cargo binaries"
  }]
  let installed = (installed-cargo-packages)
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
