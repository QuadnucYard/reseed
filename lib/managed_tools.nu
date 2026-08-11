# The shared managed binary directory, the environment variables that route
# package managers into it, and verification of declared commands.

use core.nu [expand-home]

# Shared directory where pnpm, uv, yarn, bun, and cargo-binstall place their
# executable shims, so every manager's commands resolve from one PATH entry.
export def managed-bin-dir []: nothing -> path {
  expand-home "~/.local/share/reseed/bin"
}

# Environment variables that make each package manager install into the shared
# managed binary directory. PNPM_HOME, YARN_PREFIX, and BUN_INSTALL point one
# level up because pnpm, Yarn 1, and Bun derive their bin directories relative
# to them. PATH prepends the managed bin directory because pnpm's global
# installs refuse to run when their global bin directory is absent from PATH.
export def managed-tool-environment []: nothing -> record {
  let directory = (managed-bin-dir | into string)
  let root = (managed-bin-dir | path dirname | into string)
  {
    PNPM_HOME: $root
    UV_TOOL_BIN_DIR: $directory
    YARN_PREFIX: $root
    BUN_INSTALL: $root
    CARGO_INSTALL_ROOT: $root
    PATH: ([$directory] | append $env.PATH | uniq)
  }
}

# Ensure the shared managed binary directory exists.
export def prepare-managed-bin [
  --dry-run # Only report what would be created.
] {
  if not $dry_run { mkdir (managed-bin-dir) }
}

# Absolute path of an executable in the managed bin directory for the given
# command name, or null when absent. Windows shims end in .exe/.cmd/.ps1.
export def managed-bin-command-path [
  name: string # Command name to look up.
]: nothing -> any {
  let directory = (managed-bin-dir)
  if not ($directory | path exists) { return null }
  let candidates = (ls $directory
    | where type in [file symlink]
    | get name
    | where {|path|
      let basename = ($path | path basename)
      $basename in [$name $"($name).exe" $"($name).cmd" $"($name).ps1"]
    })
  if ($candidates | is-empty) { null } else { $candidates | first }
}

# True when the named command exists in the managed bin directory.
export def managed-bin-contains [
  name: string # Command name to look up.
]: nothing -> bool {
  (managed-bin-command-path $name) != null
}

# Verification records for the commands a package declares in its manifest
# entry, one record per declared command.
export def managed-command-checks [
  manager: string # Owning manager name for the report.
  packages: list<record> # Normalized package entries with a commands list.
]: nothing -> list<record> {
  mut results = []
  for package in $packages {
    for command in ($package.commands? | default []) {
      let path = (managed-bin-command-path $command)
      $results = ($results | append {
        check: $"managed binary: ($command)"
        manager: $manager
        package: $package.name
        ok: ($path != null)
        detail: (if $path == null { $"($command) was not found in ~/.local/share/reseed/bin" } else { ($path | into string) })
      })
    }
  }
  $results
}
