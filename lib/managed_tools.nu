# Package managers retain their native roots and user configuration.
# This module also strips identifiable legacy Reseed overrides in child processes.
use core.nu [expand-home]

def path-key [value: string]: nothing -> string {
  let normalized = ($value | str replace --all "\\" "/" | str trim --right --char "/")
  if $nu.os-info.name == "windows" { $normalized | str lowercase } else { $normalized }
}

def native-root [key: string fallback: path]: nothing -> path {
  let value = ($env | get -o $key | default "")
  if ($value | str trim | is-empty) { $fallback } else { $value }
}

# Do not replace custom roots. Null values remove only old Reseed overrides
# inside with-env; the caller's environment remains unchanged.
export def package-manager-environment []: nothing -> record {
  let legacy_root = (expand-home "~/.local/share/reseed" | into string)
  let legacy_bin = ($legacy_root | path join "bin" | into string)
  let legacy_paths = [$legacy_bin ($legacy_bin | path join "bin" | into string)] | each {|p| path-key $p }
  mut environment = {}
  for key in [BUN_INSTALL PNPM_HOME YARN_PREFIX UV_TOOL_BIN_DIR CARGO_INSTALL_ROOT] {
    let value = ($env | get -o $key | default "")
    if not ($value | is-empty) and (path-key $value) in ([ $legacy_root $legacy_bin ] | each {|p| path-key $p }) {
      $environment = ($environment | upsert $key null)
    }
  }
  # pnpm requires its global bin on PATH. Its standard home is not Reseed state.
  let xdg_data = ($env.XDG_DATA_HOME? | default "")
  let pnpm_default = if not ($xdg_data | str trim | is-empty) { $xdg_data | path join "pnpm" } else if $nu.os-info.name == "windows" {
    ($env.LOCALAPPDATA? | default ($nu.home-dir | path join "AppData" "Local")) | path join "pnpm"
  } else if $nu.os-info.name == "macos" { $nu.home-dir | path join "Library" "pnpm" } else {
    $nu.home-dir | path join ".local" "share" "pnpm"
  }
  let old_pnpm = ($env.PNPM_HOME? | default "")
  let pnpm_home = if ($old_pnpm | is-empty) or (path-key $old_pnpm) in ([ $legacy_root $legacy_bin ] | each {|p| path-key $p }) {
    $environment = ($environment | upsert PNPM_HOME ($pnpm_default | into string))
    $pnpm_default
  } else { $old_pnpm }
  let inherited = ($env.PATH | where {|p| (path-key ($p | into string)) not-in $legacy_paths })
  # Verification runs before the caller necessarily reloads its shell adapter.
  # Expose native bins to child commands without changing interactive settings.
  let native_bins = (with-env $environment {
    let bun = (native-root BUN_INSTALL ($nu.home-dir | path join ".bun"))
    let uv = (native-root UV_TOOL_BIN_DIR ($nu.home-dir | path join ".local" "bin"))
    let cargo = (native-root CARGO_INSTALL_ROOT (native-root CARGO_HOME ($nu.home-dir | path join ".cargo")))
    let yarn = (native-root YARN_PREFIX ($nu.home-dir | path join ".yarn"))
    mut directories = [$pnpm_home ($pnpm_home | path join "bin") ($bun | path join "bin") $uv ($cargo | path join "bin") ($yarn | path join "bin")]
    if $nu.os-info.name == "windows" {
      $directories = ($directories | append (($env.LOCALAPPDATA? | default ($nu.home-dir | path join "AppData" "Local")) | path join "Yarn" "bin"))
    }
    $directories
  })
  $environment | upsert PATH ($inherited | append $native_bins | uniq)
}

# Resolve declared commands using normal PATH, never a Reseed-only directory.
export def package-command-checks [manager: string packages: list<record>]: nothing -> list<record> {
  mut results = []
  for package in $packages {
    for command in ($package.commands? | default []) {
      let paths = (with-env (package-manager-environment) { which $command | where type == external | get path })
      let found = not ($paths | is-empty)
      $results = ($results | append {
        check: $"package command: ($command)"
        manager: $manager
        package: $package.name
        ok: $found
        detail: (if $found { $paths | first } else { $"($command) was not found on the normal PATH" })
      })
    }
  }
  $results
}
