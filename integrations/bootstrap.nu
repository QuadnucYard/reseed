use ../lib/prelude.nu *

# The bootstrap contract: executables the engine relies on and installs
# itself. `software: false` marks tools required for the base contract
# (git, chezmoi, nu); mise is the software layer.
export def bootstrap-tools []: nothing -> list<record> {
  [
    {name: git command: git software: false detail: "required to clone and update private state"}
    {name: chezmoi command: chezmoi software: false detail: "required for configuration restore"}
    {name: nushell command: nu software: false detail: "required to run Reseed"}
    {name: mise command: mise software: true detail: "required for shared portable tools"}
  ]
}

# Installed version of an executable, parsed from its --version output.
# Empty when the executable is missing or does not report a version.
def tool-version [
  command: string # Executable name.
]: nothing -> string {
  if not (command-exists $command) { return "" }
  let output = (try { ^$command --version | complete } catch { return "" })
  if $output.exit_code != 0 { return "" }
  let text = ($output.stdout | str trim)
  if ($text | is-empty) { return "" }
  # The first version-looking token: "git version 2.47.1" -> "2.47.1",
  # "chezmoi version v2.57.0" -> "v2.57.0", mise trailing dates are skipped.
  let tokens = ($text | lines | first | split row " " | where {|field| $field != "" and ($field =~ '^[vV]?[0-9]') })
  if ($tokens | is-empty) { return "" }
  $tokens.0
}

# The bootstrap contract with per-tool availability and installed version
# reported.
export def bootstrap-status []: nothing -> list<record> {
  bootstrap-tools | each {|tool|
    $tool
    | upsert available (command-exists $tool.command)
    | upsert version (tool-version $tool.command)
  }
}

# Verification records for the bootstrap contract. --skip-software drops
# mise so offline (configuration-only) recovery can pass without it.
export def bootstrap-verify [
  --skip-software # Skip checks for mise.
]: nothing -> list<record> {
  let tools = if $skip_software {
    bootstrap-status | where {|tool| not $tool.software }
  } else {
    bootstrap-status
  }
  $tools | each {|tool|
    {
      check: $"bootstrap executable: ($tool.command)"
      ok: $tool.available
      detail: $tool.detail
    }
  }
}

# Brewfile lines owned by the bootstrap contract; native Brewfiles must not
# list these.
export def bootstrap-brew-items []: nothing -> list<string> {
  [
    'brew "git"'
    'brew "chezmoi"'
    'brew "nushell"'
    'brew "mise"'
  ]
}

# WinGet identifiers owned by the bootstrap contract; native manifests must
# not list these. The order matches bootstrap-tools so winget rows can be
# mapped back to tool names.
export def bootstrap-winget-ids []: nothing -> list<string> {
  ["Git.Git" "twpayne.chezmoi" "Nushell.Nushell" "jdx.mise"]
}

# Parse "brew outdated --formula" output into a name -> latest version
# record. Lines are "name installed < available" (brew < 4.4) or
# "name (installed: x) != y" (brew >= 4.4); only the leading name matters.
# Exported for tests.
export def parse-brew-outdated [
  text: string # Raw command output.
]: nothing -> record {
  let tools = (bootstrap-tools | get name)
  mut latest = {}
  for line in ($text | lines | each {|line| $line | str trim }) {
    let fields = ($line | split row " " | where {|field| $field != "" })
    if ($fields | is-empty) or ($fields.0 not-in $tools) { continue }
    $latest = ($latest | insert $fields.0 ($fields | last))
  }
  $latest
}

# Parse "winget list --upgrade-available" output into a name -> latest
# version record. Data rows follow the separator line and are
# "Name Id Version Available Source"; bootstrap ids map back to tool names.
# Exported for tests.
export def parse-winget-upgrade-table [
  text: string # Raw command output.
]: nothing -> record {
  let names = (bootstrap-tools | get name)
  let ids = (bootstrap-winget-ids)
  mut latest = {}
  mut in_table = false
  for line in ($text | lines | each {|line| $line | str trim }) {
    if ($line | str starts-with "---") { $in_table = true; continue }
    if not $in_table { continue }
    let fields = ($line | split row " " | where {|field| $field != "" })
    if ($fields | length) < 4 { continue }
    for index in 0..(($ids | length) - 1) {
      if $fields.1 == ($ids | get $index) {
        $latest = ($latest | insert ($names | get $index) ($fields | get 3))
      }
    }
  }
  $latest
}

# Homebrew metadata: the bootstrap tools with an available upgrade, keyed by
# tool name. Empty when brew is unavailable or the check fails.
def brew-outdated []: nothing -> record {
  let output = (try { ^brew outdated --formula | complete } catch { return {} })
  if $output.exit_code != 0 { return {} }
  parse-brew-outdated $output.stdout
}

# WinGet metadata: the bootstrap tools with an available upgrade, keyed by
# tool name. Empty when winget is unavailable or the check fails.
def winget-outdated []: nothing -> record {
  let output = (try { ^winget list --upgrade-available | complete } catch { return {} })
  if $output.exit_code != 0 { return {} }
  parse-winget-upgrade-table $output.stdout
}

# Latest available versions of the bootstrap tools from the platform package
# manager, keyed by tool name. Empty when the manager is unavailable or the
# platform has none; the check is advisory and must never fail.
export def bootstrap-latest []: nothing -> record {
  match (detect-os) {
    "macos" => (brew-outdated)
    "windows" => (winget-outdated)
    _ => {}
  }
}

# Outdated bootstrap tools with their installed and available versions.
# --skip-software drops mise so offline checks stay configuration-only.
export def bootstrap-outdated [
  --skip-software # Skip checks for mise.
]: nothing -> list<record> {
  let latest = (bootstrap-latest)
  if ($latest | is-empty) { return [] }
  let tools = if $skip_software {
    bootstrap-tools | where {|tool| not $tool.software }
  } else {
    bootstrap-tools
  }
  $tools | where {|tool| $tool.name in ($latest | columns) } | each {|tool|
    {
      name: $tool.name
      command: $tool.command
      version: (tool-version $tool.command)
      latest: ($latest | get $tool.name)
      detail: $tool.detail
    }
  }
}
