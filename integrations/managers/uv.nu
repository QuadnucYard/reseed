use ../../lib/prelude.nu *

# Specifier strings for every configured uv tool.
export def uv-packages [
  root: path # Private state root.
  config: record # Loaded configuration.
]: nothing -> list<string> {
  let configured = (manager-settings $config uv)
  mut packages = []
  for relative in ($configured.manifests? | default []) {
    $packages = ($packages | append ((read-manager-manifest $root $relative uv) | get spec))
  }
  $packages | uniq | sort
}

# Parse a uv specifier into {name, version}. Version pinning uses "=="
# (e.g. "ruff==0.12.0"); ranges and comparison operators return null.
export def uv-spec-parse [
  spec: string # Specifier such as "ruff" or "ruff==0.12.0".
]: nothing -> any {
  let parsed = ($spec | parse --regex '^(?<name>[A-Za-z0-9][A-Za-z0-9._-]*)(?:==(?<version>[A-Za-z0-9][A-Za-z0-9.+_-]*))?$')
  if ($parsed | is-empty) {
    null
  } else {
    let row = ($parsed | first)
    {name: ($row.name | str lowercase) version: ($row | get -o version | default null)}
  }
}

# Normalize a specifier plus declared commands into a package record.
export def uv-package-record [
  spec: string # Package specifier.
  commands: list<string> = [] # Commands the package installs.
]: nothing -> record {
  let parsed = (uv-spec-parse $spec)
  if $parsed == null {
    return {spec: $spec name: ($spec | str lowercase) version: null commands: ($commands | uniq)}
  }
  {
    spec: $spec
    name: $parsed.name
    version: $parsed.version
    commands: ($commands | uniq)
  }
}

# All configured uv tools across manifests, merged by specifier.
export def uv-entries [
  root: path # Private state root.
  config: record # Loaded configuration.
]: nothing -> list<record> {
  let configured = (manager-settings $config uv)
  mut packages = []
  for relative in ($configured.manifests? | default []) {
    let entries = (read-manager-manifest $root $relative uv)
    for entry in $entries {
      if (uv-spec-parse $entry.spec) == null {
        error make {msg: $"Unsupported package specifier '($entry.spec)' in ($relative); use name or name==version"}
      }
      $packages = ($packages | append (uv-package-record $entry.spec $entry.commands))
    }
  }
  merge-package-entries $packages
}

# Install or upgrade one uv tool through mise exec. --upgrade makes the
# command idempotent and also refreshes an installed tool of the same name.
def run-uv-package [
  root: path # Private state root.
  config: record # Loaded configuration.
  package: string # Specifier to install.
  --dry-run # Show the command without running it.
] {
  run-mise-managed $root $config "uv" ["tool" "install" "--upgrade" $package] "mise is required for the configured uv tools" --dry-run=$dry_run | ignore
}

# Install every configured uv tool.
export def uv-restore [
  root: path # Private state root.
  config: record # Loaded configuration.
  --dry-run # Show the installs without running them.
] {
  let configured = (manager-settings $config uv)
  if not ($configured.enabled? | default false) { return }
  for package in (uv-packages $root $config) {
    run-uv-package $root $config $package --dry-run=$dry_run
  }
}

# Upgrade every configured uv tool.
export def uv-update [
  root: path # Private state root.
  config: record # Loaded configuration.
  --dry-run # Show the upgrades without running them.
] {
  let configured = (manager-settings $config uv)
  if not ($configured.enabled? | default false) or not ($configured.update? | default true) { return }
  if not $dry_run and not (command-exists mise) {
    warning "mise is unavailable; skipping uv tool updates"
    return
  }
  for package in (uv-packages $root $config) {
    run-uv-package $root $config $package --dry-run=$dry_run
  }
}

# Parse "uv tool list --show-version-specifiers" output ("name v1.2.3" lines)
# into {name, version} records.
export def parse-uv-inventory [output: string]: nothing -> list<record> {
  $output
    | lines
    | each {|line|
      let parsed = ($line | parse --regex '^(?<name>[A-Za-z0-9][A-Za-z0-9._-]*)\s+v(?<version>[^\s]+)')
      if ($parsed | is-empty) {
        null
      } else {
        let row = ($parsed | first)
        {name: ($row.name | str lowercase) version: $row.version}
      }
    }
    | compact
    | uniq
    | sort-by name
}

# Installed uv tools, or {available: false} with a reason when the inventory
# cannot be produced.
def installed-uv-packages [
  root: path # Private state root.
  config: record # Loaded configuration.
]: nothing -> record {
  if not (command-exists mise) {
    return {available: false packages: [] detail: "mise is unavailable"}
  }
  let result = (try {
    run-mise-managed $root $config "uv" ["tool" "list" "--show-version-specifiers"] "mise is required for the configured uv tools" --allow-failure --capture
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
  let packages = (parse-uv-inventory $result.stdout)
  {available: true packages: $packages detail: "uv tool inventory"}
}

# Desired uv tools that are missing or at the wrong version.
export def uv-missing-packages [
  desired: list<record> # Normalized desired package records.
  installed: list<record> # Installed {name, version} records.
]: nothing -> list<record> {
  missing-packages $desired $installed
}

# Compare desired uv tools with the installed inventory, report-only.
export def uv-reconcile [
  root: path # Private state root.
  config: record # Loaded configuration.
  --dry-run # Skip the live inventory.
]: nothing -> record {
  let configured = (manager-settings $config uv)
  if not ($configured.enabled? | default false) {
    return {tool: uv applicable: false desired_only: [] observed_only: []}
  }
  manager-reconcile uv (uv-entries $root $config) { installed-uv-packages $root $config } --dry-run=$dry_run
}

# Verification checks for uv: executable presence, tool presence, and every
# command declared in the manifests.
export def uv-verify [
  root: path # Private state root.
  config: record # Loaded configuration.
]: nothing -> list<record> {
  let configured = (manager-settings $config uv)
  if not ($configured.enabled? | default false) { return [] }
  manager-verify uv (uv-entries $root $config) { installed-uv-packages $root $config } "tool"
}
