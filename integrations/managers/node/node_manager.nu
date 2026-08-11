use ../../../lib/prelude.nu *

# Fail unless the manager is one of the supported Node package managers.
def supported-manager [
  manager: string # Manager name to check.
]: nothing -> nothing {
  if $manager not-in [pnpm yarn bun] {
    error make {msg: $"Unsupported Node package manager: ($manager)"}
  }
}

# Manager settings from the configuration for the given Node manager.
def settings [
  config: record # Loaded configuration.
  manager: string # Manager name.
]: nothing -> record {
  supported-manager $manager
  manager-settings $config $manager
}

# Parse a Node package specifier into {name, version}. Supports unscoped and
# scoped names (@scope/name) with an optional @version; anything else (npm
# aliases, ranges, tags other than "latest") returns null.
export def node-spec-parse [
  spec: string # Specifier such as "pkg" or "@scope/name@1.2.3".
]: nothing -> any {
  let scoped = ($spec | parse --regex '^(?<name>@[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*)(?:@(?<version>[A-Za-z0-9][A-Za-z0-9.+_-]*))?$')
  if not ($scoped | is-empty) {
    let row = ($scoped | first)
    return {name: ($row.name | str lowercase) version: ($row | get -o version | default null)}
  }
  let unscoped = ($spec | parse --regex '^(?<name>[A-Za-z0-9][A-Za-z0-9._-]*)(?:@(?<version>[A-Za-z0-9][A-Za-z0-9.+_-]*))?$')
  if ($unscoped | is-empty) {
    null
  } else {
    let row = ($unscoped | first)
    {name: ($row.name | str lowercase) version: ($row | get -o version | default null)}
  }
}

# Normalize a specifier plus declared commands into a package record. The
# "latest" tag normalizes to no pinned version.
export def node-package-record [
  spec: string # Package specifier.
  commands: list<string> = [] # Commands the package installs.
]: nothing -> record {
  let parsed = (node-spec-parse $spec)
  if $parsed == null {
    return {spec: $spec name: ($spec | str lowercase) version: null commands: ($commands | uniq)}
  }
  {
    spec: $spec
    name: $parsed.name
    version: (if $parsed.version == "latest" { null } else { $parsed.version })
    commands: ($commands | uniq)
  }
}

# All configured packages for a Node manager across its manifests, merged by
# specifier so duplicate declarations combine their commands.
export def node-manager-entries [
  root: path # Private state root.
  config: record # Loaded configuration.
  manager: string # Manager name (pnpm, yarn, or bun).
]: nothing -> list<record> {
  let configured = (settings $config $manager)
  mut packages = []
  for relative in ($configured.manifests? | default []) {
    let entries = (read-manager-manifest $root $relative $manager)
    for entry in $entries {
      if (node-spec-parse $entry.spec) == null {
        error make {msg: $"Unsupported package specifier '($entry.spec)' in ($relative); use name or name@version"}
      }
      $packages = ($packages | append (node-package-record $entry.spec $entry.commands))
    }
  }
  merge-package-entries $packages
}

# Specifier strings for every configured package of a Node manager.
export def node-manager-packages [
  root: path # Private state root.
  config: record # Loaded configuration.
  manager: string # Manager name.
]: nothing -> list<string> {
  node-manager-entries $root $config $manager | get spec
}

# Arguments that install a specifier as a global package for the manager.
export def node-manager-install-args [
  manager: string # Manager name.
  spec: string # Package specifier.
]: nothing -> list<string> {
  match $manager {
    pnpm => [add --global $spec]
    yarn => [global add $spec]
    bun => [add --global $spec]
  }
}

# Arguments that update a package: reinstall the pinned specifier when a
# version is recorded, otherwise upgrade to the latest for the manager.
export def node-manager-update-args [
  manager: string # Manager name.
  package: record # Normalized package record.
]: nothing -> list<string> {
  if $package.version != null {
    return (node-manager-install-args $manager $package.spec)
  }
  match $manager {
    pnpm => [update --global --latest $package.name]
    yarn => [global upgrade --latest $package.name]
    bun => [update --global $package.name]
  }
}

# Major version parsed from a "1.22.19" style version string; 0 when the
# output does not start with a numeric version.
export def node-yarn-major-version [
  output: string # Version string such as "1.22.19".
]: nothing -> int {
  let parsed = ($output | str trim | parse --regex '^(?<major>\d+)\.')
  if ($parsed | is-empty) { 0 } else { $parsed | first | get major | into int }
}

# Fail when the Yarn integration would not work. Reseed's Yarn support relies
# on the removed-in-Yarn-2 "yarn global" commands, so only Yarn 1 is usable.
def require-yarn-global [
  root: path # Private state root.
  config: record # Loaded configuration.
  manager: string # Manager name.
  --dry-run # Skip the availability probe.
] {
  if $manager != "yarn" or $dry_run { return }
  if not (command-exists mise) {
    error make {msg: "mise is required for configured yarn globals"}
  }
  let result = (try {
    run-mise-managed $root $config yarn ["--version"] "mise is required for configured yarn globals" --allow-failure --capture
  } catch {|error|
    {exit_code: 127 stdout: "" stderr: ($error.msg? | default ($error | to nuon))}
  })
  if $result.exit_code != 0 {
    error make {msg: "yarn is unavailable; Reseed's Yarn integration requires Yarn 1"}
  }
  let major = (node-yarn-major-version $result.stdout)
  if $major >= 2 {
    error make {msg: $"Reseed's Yarn integration requires Yarn 1, which provides the 'yarn global' commands, but Yarn ($major) was found; pin Yarn 1.x in the mise config"}
  }
}

# Run a manager command through mise exec with the shared managed-tools
# environment so globals install into the managed bin directory.
def run-node-manager [
  root: path # Private state root.
  config: record # Loaded configuration.
  manager: string # Manager name.
  args: list<string> # Manager arguments.
  --dry-run # Show the command without running it.
  --allow-failure # Return the result instead of failing on nonzero exit.
  --capture # Collect stdout/stderr into the result instead of streaming them.
]: nothing -> record {
  run-mise-managed $root $config $manager $args $"mise is required for configured ($manager) globals" --dry-run=$dry_run --allow-failure=$allow_failure --capture=$capture
}

# Install every configured global package for a Node manager. A failed
# install warns and is counted so the workflow can fail with a summary.
export def node-manager-restore [
  root: path # Private state root.
  config: record # Loaded configuration.
  manager: string # Manager name.
  --dry-run # Show the installs without running them.
]: nothing -> int {
  let configured = (settings $config $manager)
  if not ($configured.enabled? | default false) { return 0 }
  require-yarn-global $root $config $manager --dry-run=$dry_run
  mut failures = 0
  for package in (node-manager-entries $root $config $manager) {
    let result = (run-node-manager $root $config $manager (node-manager-install-args $manager $package.spec) --dry-run=$dry_run --allow-failure)
    if $result.exit_code != 0 {
      warning $"($manager) failed to install ($package.spec) with exit code ($result.exit_code); continuing"
      $failures += 1
    }
  }
  $failures
}

# Update every configured global package for a Node manager. A failed update
# warns and is counted so the workflow can fail with a summary.
export def node-manager-update [
  root: path # Private state root.
  config: record # Loaded configuration.
  manager: string # Manager name.
  --dry-run # Show the updates without running them.
]: nothing -> int {
  let configured = (settings $config $manager)
  if not ($configured.enabled? | default false) or not ($configured.update? | default true) { return 0 }
  if not $dry_run and not (command-exists mise) {
    warning $"mise is unavailable; skipping ($manager) global updates"
    return 0
  }
  require-yarn-global $root $config $manager --dry-run=$dry_run
  mut failures = 0
  for package in (node-manager-entries $root $config $manager) {
    let result = (run-node-manager $root $config $manager (node-manager-update-args $manager $package) --dry-run=$dry_run --allow-failure)
    if $result.exit_code != 0 {
      warning $"($manager) failed to update ($package.spec) with exit code ($result.exit_code); continuing"
      $failures += 1
    }
  }
  $failures
}

# Parse a dependency inventory (pnpm --json or bun JSON output) into
# {name, version} records. Nested dependency maps are flattened and versions
# may be strings or records.
def parse-dependency-inventory [parsed: any]: nothing -> list<record> {
  let roots = if (($parsed | describe) | str starts-with "list") { $parsed } else { [$parsed] }
  mut packages = []
  for root in $roots {
    let dependencies = ($root.dependencies? | default {})
    if (($dependencies | describe) | str starts-with "record") {
      for item in ($dependencies | transpose key value) {
        let value = ($item.value | default {})
        let version = if (($value | describe) | str starts-with "record") {
          $value.version? | default null
        } else if (($value | describe) == "string") {
          $value
        } else {
          null
        }
        $packages = ($packages | append {name: ($item.key | str lowercase) version: $version})
      }
    }
  }
  $packages | uniq | sort-by name
}

# Recursively collect package records from a yarn JSON tree node.
def yarn-node-packages [node: any]: nothing -> list<record> {
  mut packages = []
  let name = ($node.name? | default null)
  if $name != null and ($name | describe) == "string" {
    let package = (node-package-record $name)
    $packages = ($packages | append {name: $package.name version: $package.version})
  }
  for child in ($node.children? | default []) {
    $packages = ($packages | append (yarn-node-packages $child))
  }
  $packages
}

# Parse a pnpm or bun JSON dependency inventory.
export def parse-node-dependency-inventory [parsed: any]: nothing -> list<record> {
  parse-dependency-inventory $parsed
}

# Parse yarn "global list --json" output: a stream of JSONL events, of which
# only "tree" events carry the package inventory.
export def parse-yarn-inventory [output: string]: nothing -> list<record> {
  mut packages = []
  for line in ($output | lines) {
    let event = (try { $line | from json } catch { null })
    if $event == null { continue }
    if ($event.type? | default "") == "tree" {
      for node in ($event.data? | default []) {
        $packages = ($packages | append (yarn-node-packages $node))
      }
    }
  }
  $packages | flatten | uniq | sort-by name
}

# Fallback parser for bun text-mode inventory output when JSON is unavailable.
def parse-bun-text-inventory [output: string]: nothing -> list<record> {
  mut packages = []
  for line in ($output | lines) {
    let tokens = ($line | str trim | split row " " | where {|token| not ($token | is-empty) })
    if ($tokens | is-empty) { continue }
    let candidate = ($tokens | last)
    if not ($candidate | str contains "@") { continue }
    let package = (node-package-record $candidate)
    $packages = ($packages | append {name: $package.name version: $package.version})
  }
  $packages | uniq | sort-by name
}

# Parse bun global inventory, preferring JSON output and falling back to the
# plain-text listing.
export def parse-bun-inventory [output: string]: nothing -> list<record> {
  let parsed = (try {
    {ok: true value: ($output | from json)}
  } catch {
    {ok: false}
  })
  if $parsed.ok {
    parse-dependency-inventory $parsed.value
  } else {
    parse-bun-text-inventory $output
  }
}

# Run the inventory command for a manager and return its result record.
def inventory-output [
  root: path # Private state root.
  config: record # Loaded configuration.
  manager: string # Manager name.
]: nothing -> record {
  let args = match $manager {
    pnpm => [list --global --depth "0" --json]
    yarn => [global list --json]
    bun => [pm ls --global --json]
  }
  let result = (try {
    run-node-manager $root $config $manager $args --allow-failure --capture
  } catch {|error|
    {exit_code: 127 stdout: "" stderr: ($error.msg? | default ($error | to nuon))}
  })
  {result: $result}
}

# Installed global packages for a manager, or {available: false} with a
# reason when the inventory cannot be produced.
def installed-packages [
  root: path # Private state root.
  config: record # Loaded configuration.
  manager: string # Manager name.
]: nothing -> record {
  if not (command-exists mise) {
    return {available: false packages: [] detail: "mise is unavailable"}
  }
  let output = (inventory-output $root $config $manager)
  if $output.result.exit_code != 0 {
    return {available: false packages: [] detail: ($output.result.stderr | str trim)}
  }
  if $manager == "yarn" {
    return {available: true packages: (parse-yarn-inventory $output.result.stdout) detail: "yarn global inventory"}
  }
  if $manager == "bun" {
    return {available: true packages: (parse-bun-inventory $output.result.stdout) detail: "bun global inventory"}
  }
  let parsed = (try {
    {ok: true value: ($output.result.stdout | from json)}
  } catch {|error|
    {ok: false detail: ($error.msg? | default ($error | to nuon))}
  })
  if not $parsed.ok {
    return {available: false packages: [] detail: $parsed.detail}
  }
  {available: true packages: (parse-dependency-inventory $parsed.value) detail: $"($manager) global inventory"}
}

# Desired packages that are not present: either not installed at all or
# installed at a different version than pinned.
export def node-manager-missing-packages [
  desired: list<record> # Normalized desired package records.
  installed: list<record> # Installed {name, version} records.
]: nothing -> list<record> {
  missing-packages $desired $installed
}

# Compare desired globals with the installed inventory for a manager,
# report-only.
export def node-manager-reconcile [
  root: path # Private state root.
  config: record # Loaded configuration.
  manager: string # Manager name.
  --dry-run # Skip the live inventory.
]: nothing -> record {
  let configured = (settings $config $manager)
  if not ($configured.enabled? | default false) {
    return {tool: $manager applicable: false desired_only: [] observed_only: []}
  }
  manager-reconcile $manager (node-manager-entries $root $config $manager) { installed-packages $root $config $manager } --dry-run=$dry_run
}

# Verification checks for a Node manager: executable availability, globals
# presence, and every command declared in the manifests.
export def node-manager-verify [
  root: path # Private state root.
  config: record # Loaded configuration.
  manager: string # Manager name.
]: nothing -> list<record> {
  let configured = (settings $config $manager)
  if not ($configured.enabled? | default false) { return [] }
  manager-verify $manager (node-manager-entries $root $config $manager) { installed-packages $root $config $manager } "global"
}
