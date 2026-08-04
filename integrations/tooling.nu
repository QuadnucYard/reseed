use ../lib/core.nu [command-exists expand-home run-command warning]
use ../lib/state.nu [observation-dir]

def migration-hint [manager: string]: nothing -> string {
  match $manager {
    cargo => 'Move portable crates to mise.toml as "cargo:<crate>" = "latest".'
    pnpm | npm | yarn | bun => 'Move portable JavaScript CLIs to mise.toml as "npm:<package>" = "latest".'
    uv => 'Move portable Python CLIs to mise.toml through the pipx backend when compatible.'
    _ => "Review this native inventory and keep only tools that cannot be owned by mise."
  }
}

def observe-command [
  config: record
  manager: string
  program: string
  args: list<string>
  filename: string
  --dry-run
]: nothing -> record {
  let target = (observation-dir $config | path join $filename)
  let available = (command-exists $program)
  if not $available {
    return {
      manager: $manager
      available: false
      ok: false
      observation: ($target | into string)
      detail: $"($program) is unavailable"
      migration: (migration-hint $manager)
    }
  }

  let result = (try {
    run-command $program $args --allow-failure --dry-run=$dry_run
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

def observe-bun [config: record --dry-run]: nothing -> record {
  let install_root = ($env.BUN_INSTALL? | default (expand-home "~/.bun"))
  let source = ($install_root | path join "install" "global" "package.json")
  let target = (observation-dir $config | path join "bun-global-package.json")
  let available = (command-exists bun)
  if not $available {
    return {
      manager: bun
      available: false
      ok: false
      observation: ($target | into string)
      detail: "bun is unavailable"
      migration: (migration-hint bun)
    }
  }
  if $dry_run {
    return {
      manager: bun
      available: $available
      ok: true
      observation: ($target | into string)
      detail: "would capture"
      migration: (migration-hint bun)
    }
  }
  if not ($source | path exists) {
    return {
      manager: bun
      available: (command-exists bun)
      ok: false
      observation: ($target | into string)
      detail: $"global package manifest not found: ($source)"
      migration: (migration-hint bun)
    }
  }
  let copied = (try {
    mkdir ($target | path dirname)
    cp $source $target
    {ok: true detail: "captured"}
  } catch {|error|
    {ok: false detail: ($error.msg? | default ($error | to nuon))}
  })
  {
    manager: bun
    available: $available
    ok: $copied.ok
    observation: ($target | into string)
    detail: $copied.detail
    migration: (migration-hint bun)
  }
}

export def tooling-observe [config: record --dry-run]: nothing -> list<record> {
  let managers = ($config.observations.tool_managers? | default [])
  mut results = []
  for manager in $managers {
    let observed = match $manager {
      cargo => [(observe-command $config cargo cargo ["install" "--list"] "cargo-install.txt" --dry-run=$dry_run)]
      pnpm => [(observe-command $config pnpm pnpm ["list" "-g" "--depth" "0" "--json"] "pnpm-global.json" --dry-run=$dry_run)]
      bun => [(observe-bun $config --dry-run=$dry_run)]
      uv => [
        (observe-command $config uv uv ["tool" "list" "--show-version-specifiers" "--show-with" "--show-extras" "--show-python"] "uv-tools.txt" --dry-run=$dry_run)
        (observe-command $config uv uv ["python" "list" "--only-installed" "--output-format" "json"] "uv-python.json" --dry-run=$dry_run)
      ]
      npm => [(observe-command $config npm npm ["ls" "-g" "--depth" "0" "--json"] "npm-global.json" --dry-run=$dry_run)]
      yarn => [(observe-command $config yarn yarn ["global" "list" "--json"] "yarn-global.jsonl" --dry-run=$dry_run)]
      _ => [{
        manager: $manager
        available: false
        ok: false
        observation: ""
        detail: "unknown observation manager"
        migration: "Remove it from observations.tool_managers or add an integration."
      }]
    }
    $results = ($results | append $observed)
  }
  $results
}

export def tooling-backup [config: record --dry-run] {
  let results = (tooling-observe $config --dry-run=$dry_run)
  let failures = ($results | where {|item| not $item.ok })
  for failure in $failures {
    warning $"Tool observation incomplete for ($failure.manager): ($failure.detail)"
  }
}
