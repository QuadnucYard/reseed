# Manager-agnostic plumbing shared by the uv, Cargo-binstall, and Node
# package manager integrations: manifest reading, entry merging,
# missing-package detection, and the reconcile/verify report builders.

use core.nu [fail require-file]
use managed_tools.nu [managed-command-checks]

# Settings record for a package manager nested under software.mise.
export def manager-settings [
  config: record # Loaded configuration.
  manager: string # Manager key, e.g. uv, pnpm, yarn, bun, or cargo_binstall.
]: nothing -> record {
  ($config.software.mise? | default {}) | get -o $manager | default {}
}

# Read a manager manifest (uv, pnpm, yarn, or bun) and normalize every entry
# into {spec, commands}. Entries may be bare strings or records with a
# non-empty spec and an optional list of declared commands.
export def read-manager-manifest [
  root: path # Private state root the manifest is relative to.
  relative: string # Manifest path relative to the root.
  manager: string # Manager name used in error messages.
]: nothing -> list<record> {
  let path = ($root | path join $relative)
  if not ($path | path exists) {
    error make {msg: $"Missing ($manager) manifest: ($relative)"}
  }
  let manifest = (open $path)
  if ($manifest.schema? | default 0) != 1 {
    error make {msg: $"Unsupported ($manager) manifest schema: ($relative)"}
  }
  let listed = ($manifest.packages? | default null)
  let listed_kind = if $listed == null { "nothing" } else { $listed | describe }
  if $listed == null or not (($listed_kind | str starts-with "list") or ($listed_kind | str starts-with "table")) {
    error make {msg: $"($manager) manifest packages must be a list: ($relative)"}
  }
  $listed | each {|entry| manager-package-entry $entry $manager $relative }
}

# Normalize a single manifest entry (string or spec/commands record) into a
# {spec, commands} record, rejecting anything else. Declared commands are
# deduplicated.
export def manager-package-entry [
  entry: any # Raw manifest entry: a string or a spec/commands record.
  manager: string # Manager name used in error messages.
  relative: string # Manifest path used in error messages.
]: nothing -> record {
  let kind = ($entry | describe)
  if $kind == "string" {
    if (($entry | str trim) | is-empty) {
      error make {msg: $"($manager) manifest entries must not be empty: ($relative)"}
    }
    return {spec: $entry commands: []}
  }
  if not ($kind | str starts-with "record") {
    error make {msg: $"($manager) manifest entries must be strings or records with spec and commands: ($relative)"}
  }
  let spec = ($entry.spec? | default null)
  let commands = ($entry.commands? | default [])
  if $spec == null or ($spec | describe) != "string" or (($spec | str trim) | is-empty) {
    error make {msg: $"($manager) manifest record spec must be a non-empty string: ($relative)"}
  }
  if not (($commands | describe) | str starts-with "list") or not ($commands | all {|command| ($command | describe) == "string" and not (($command | str trim) | is-empty) }) {
    error make {msg: $"($manager) manifest record commands must be a list of non-empty strings: ($relative)"}
  }
  {spec: $spec commands: ($commands | uniq)}
}

# Merge package records by specifier so duplicate declarations combine their
# command lists, sorted by specifier.
export def merge-package-entries [
  entries: list<record> # Normalized package records, possibly with duplicates.
]: nothing -> list<record> {
  $entries
    | group-by spec
    | transpose spec entries
    | each {|group|
        let first = ($group.entries | first)
        {
          spec: $group.spec
          name: $first.name
          version: $first.version
          commands: ($group.entries | each {|item| $item.commands } | flatten | uniq | sort)
        }
      }
    | sort-by spec
}

# Desired packages that are not present: either not installed at all or
# installed at a different version than pinned.
export def missing-packages [
  desired: list<record> # Normalized desired package records.
  installed: list<record> # Installed {name, version} records.
]: nothing -> list<record> {
  $desired | where {|item|
    let matches = ($installed | where name == $item.name)
    ($matches | is-empty) or (($item.version != null) and not ($matches | any {|entry| $entry.version == $item.version }))
  }
}

# Reconcile result for a manager: desired-only and observed-only package
# lists. The inventory closure is only invoked outside dry runs.
export def manager-reconcile [
  tool: string # Tool name for the report.
  desired: list<record> # Normalized desired package records.
  inventory: closure # Closure returning {available, packages, detail?}.
  --dry-run # Skip the live inventory.
]: nothing -> record {
  if $dry_run {
    return {tool: $tool applicable: true desired_only: [] observed_only: [] detail: "dry run"}
  }
  let installed = (do $inventory)
  if not ($installed.available? | default false) {
    return {tool: $tool applicable: true error: ($installed.detail? | default "unknown") desired_only: ($desired | get spec) observed_only: []}
  }
  let missing = (missing-packages $desired $installed.packages)
  let desired_names = ($desired | get name)
  {
    tool: $tool
    applicable: true
    desired_only: ($missing | get spec)
    observed_only: ($installed.packages | where name not-in $desired_names | get name)
  }
}

# Verification checks shared by all manager integrations: executable
# presence, desired-package presence, and every declared command. The
# inventory closure is only invoked when the manager is enabled.
export def manager-verify [
  manager: string # Manager name for the report.
  desired: list<record> # Normalized desired package records.
  inventory: closure # Closure returning {available, packages, detail?}.
  unit: string # Package kind for labels, e.g. "tool" or "global".
]: nothing -> list<record> {
  let installed = (do $inventory)
  let missing = if ($installed.available? | default false) {
    missing-packages $desired $installed.packages
  } else {
    $desired
  }
  mut results = [
    {
      check: $"($manager) executable"
      ok: ($installed.available? | default false)
      detail: (if ($installed.available? | default false) {
        $"required for configured ($manager) ($unit)s"
      } else {
        $"($manager) is unavailable: ($installed.detail? | default 'the inventory command failed')"
      })
    }
    {
      check: $"($manager) ($unit)s"
      ok: ($missing | is-empty)
      detail: (if ($missing | is-empty) { $"all configured ($manager) ($unit)s installed" } else { $"missing: (($missing | get spec) | str join ', ')" })
    }
  ]
  $results | append (managed-command-checks $manager $desired)
}
