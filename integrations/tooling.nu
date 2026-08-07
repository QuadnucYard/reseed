use ../lib/prelude.nu *

# Migration hint shown when an observation manager cannot be captured, so the
# user knows where to move the inventory entries.
def migration-hint [
  manager: string # Manager name.
]: nothing -> string {
  match $manager {
    cargo => 'Move portable crates to the configured packages/cargo/binstall.nuon manifest.'
    pnpm => 'Move global JavaScript CLIs to packages/node/pnpm/global.nuon.'
    yarn => 'Move global JavaScript CLIs to packages/node/yarn/global.nuon.'
    bun => 'Move global JavaScript CLIs to packages/node/bun/global.nuon.'
    npm => 'Move portable JavaScript CLIs to mise.toml or a supported Node manager manifest.'
    uv => 'Move Python CLI tools to the configured packages/uv manifest.'
    _ => "Review this native inventory and keep only tools that cannot be owned by mise."
  }
}

# Run a manager's inventory command and save its stdout to the observations
# directory. When the manager is owned by mise, the command runs through
# "mise exec" so it sees the same environment as installed tools.
def observe-command [
  config: record # Loaded configuration.
  manager: string # Manager name for the report.
  program: string # Executable to run.
  args: list<string> # Inventory arguments.
  filename: string # Observation file name.
  --mise-config: path = "" # Mise config; non-empty runs through mise exec.
  --environment: record = {} # Extra environment for the child.
  --dry-run # Report what would be captured without writing.
]: nothing -> record {
  let target = (observation-dir $config | path join $filename)
  let managed = not (($mise_config | into string | str trim) | is-empty)
  let actual_program = if $managed { "mise" } else { $program }
  let actual_args = if $managed { mise-exec-args $mise_config $program $args } else { $args }
  let available = (command-exists $actual_program)
  if not $available {
    return {
      manager: $manager
      available: false
      ok: false
      observation: ($target | into string)
      detail: $"($actual_program) is unavailable"
      migration: (migration-hint $manager)
    }
  }

  let result = (try {
    run-command $actual_program $actual_args --environment=$environment --allow-failure --dry-run=$dry_run --capture
  } catch {|error|
    {
      exit_code: 127
      stdout: ""
      stderr: ($error.msg? | default ($error | to nuon))
      skipped: false
    }
  })
  if (not $dry_run) and ($result.exit_code == 0) {
    mkdir ($target | path dirname)
    $result.stdout | save --force $target
  }
  {
    manager: $manager
    available: $available
    ok: ($result.exit_code == 0)
    observation: ($target | into string)
    detail: (if $dry_run { "would capture" } else if $result.exit_code == 0 { "captured" } else { ($result.stderr | str trim) })
    migration: (migration-hint $manager)
  }
}

# Run the configured inventory commands for one manager, returning its
# observation records.
def observe-manager [
  config: record # Loaded configuration.
  manager: string # Manager name.
  mise_enabled: bool # Whether commands run through mise exec.
  manager_config: path # Mise config to exec through when enabled.
  --dry-run # Report what would be captured without writing.
]: nothing -> list<record> {
  let environment = if $mise_enabled { managed-tool-environment } else { {} }
  let mise = if $mise_enabled { $manager_config } else { "" }
  match $manager {
    cargo => [(observe-command $config cargo cargo ["install" "--list"] "cargo-install.txt" --mise-config=$mise --environment=$environment --dry-run=$dry_run)]
    pnpm => [(observe-command $config pnpm pnpm ["list" "-g" "--depth" "0" "--json"] "pnpm-global.json" --mise-config=$mise --environment=$environment --dry-run=$dry_run)]
    bun => [(observe-command $config bun bun ["pm" "ls" "--global" "--json"] "bun-global-package.json" --mise-config=$mise --environment=$environment --dry-run=$dry_run)]
    uv => [
      (observe-command $config uv uv ["tool" "list" "--show-version-specifiers" "--show-with" "--show-extras" "--show-python"] "uv-tools.txt" --mise-config=$mise --environment=$environment --dry-run=$dry_run)
      (observe-command $config uv uv ["python" "list" "--only-installed" "--output-format" "json"] "uv-python.json" --mise-config=$mise --environment=$environment --dry-run=$dry_run)
    ]
    npm => [(observe-command $config npm npm ["ls" "-g" "--depth" "0" "--json"] "npm-global.json" --mise-config=$mise --environment=$environment --dry-run=$dry_run)]
    yarn => [(observe-command $config yarn yarn ["global" "list" "--json"] "yarn-global.jsonl" --mise-config=$mise --environment=$environment --dry-run=$dry_run)]
    _ => [{
      manager: $manager
      available: false
      ok: false
      observation: ""
      detail: "unknown observation manager"
      migration: "Remove it from observations.tool_managers or add an integration."
    }]
  }
}

# Capture inventory observations for every configured tool manager, running
# them through mise when the portable-tools layer is enabled.
export def tooling-observe [
  root: path # Private state root.
  config: record # Loaded configuration.
  --dry-run # Report what would be captured without writing.
]: nothing -> list<record> {
  let managers = ($config.observations.tool_managers? | default [])
  let mise_enabled = ($config.software.mise.enabled? | default false)
  let manager_config = if $mise_enabled { mise-manager-config $root $config } else { "" }
  mut results = []
  for manager in $managers {
    $results = ($results | append (observe-manager $config $manager $mise_enabled $manager_config --dry-run=$dry_run))
  }
  $results
}

# Backup step that captures tool observations and warns about any manager
# that could not be captured.
export def tooling-backup [
  root: path # Private state root.
  config: record # Loaded configuration.
  --dry-run # Show the captures without writing.
] {
  let results = (tooling-observe $root $config --dry-run=$dry_run)
  let failures = ($results | where {|item| not $item.ok })
  for failure in $failures {
    warning $"Tool observation incomplete for ($failure.manager): ($failure.detail)"
  }
}
