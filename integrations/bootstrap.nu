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

# The bootstrap contract with per-tool availability reported.
export def bootstrap-status []: nothing -> list<record> {
  bootstrap-tools | each {|tool|
    $tool | upsert available (command-exists $tool.command)
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
# not list these.
export def bootstrap-winget-ids []: nothing -> list<string> {
  ["Git.Git" "twpayne.chezmoi" "Nushell.Nushell" "jdx.mise"]
}
