# Mise command construction and execution: config contexts, exec arguments,
# backend dependency rules, and running managers through mise.

use core.nu [command-exists run-command]
use managed_tools.nu [managed-tool-environment]

# Resolve the directory and optional environment a mise config applies to.
# Plain "mise.toml" has no environment; "mise.<environment>.toml" names one.
def mise-context [
  path: path # Mise config file.
]: nothing -> record {
  let name = ($path | path basename)
  let directory = ($path | path dirname | into string)
  if $name == "mise.toml" {
    return {directory: $directory environment: null}
  }

  let parsed = ($name | parse --regex '^mise\.(?<environment>[A-Za-z0-9_-]+)\.toml$')
  if ($parsed | is-empty) {
    error make {msg: $"Unsupported mise config name '($name)'; use mise.toml or mise.<environment>.toml"}
  }
  {directory: $directory environment: ($parsed | first | get environment)}
}

# Build mise CLI prefix arguments for a config path: -C for the directory and
# -E for the environment when the config targets one.
export def mise-args [
  path: path # Mise config file.
  args: list<string> # Arguments to append after the -C/-E prefix.
]: nothing -> list<string> {
  let context = (mise-context $path)
  mut prefix = ["-C" $context.directory]
  if $context.environment != null {
    $prefix = ($prefix | append ["-E" $context.environment])
  }
  $prefix | append $args
}

# Build mise exec arguments that run a program through the config's toolset.
export def mise-exec-args [
  path: path # Mise config file.
  program: string # Program to run inside the mise environment.
  args: list<string> = [] # Arguments to the program.
]: nothing -> list<string> {
  mise-args $path ((["exec" "--" $program] | append $args))
}

# Run a program through the manager mise config with the shared managed-tools
# environment, so package managers install into the managed bin directory.
# Fails when mise is missing unless --dry-run is set.
export def run-mise-managed [
  root: path # Private state root.
  config: record # Loaded configuration.
  program: string # Program to run inside mise.
  args: list<string> # Arguments for the program.
  requirement: string # Error message when mise is unavailable.
  --dry-run # Show the command without running it.
  --allow-failure # Return the result instead of failing on nonzero exit.
  --capture # Collect stdout/stderr into the result instead of streaming them.
]: nothing -> record {
  if not $dry_run and not (command-exists mise) {
    error make {msg: $requirement}
  }
  let mise_config = (mise-manager-config $root $config)
  run-command mise (mise-exec-args $mise_config $program $args) --environment=(managed-tool-environment) --dry-run=$dry_run --allow-failure=$allow_failure --capture=$capture
}

# Read the [tools] table of a mise config as a record of tool name to spec.
def tool-record [
  path: path # Mise config file.
]: nothing -> record {
  let manifest = (open $path)
  let tools = ($manifest.tools? | default {})
  if not (($tools | describe) | str starts-with "record") {
    error make {msg: $"Mise config must contain a [tools] table: ($path)"}
  }
  $tools
}

# Backend-qualified tools in a mise config whose host runtime is declared in
# [tools]. For example "npm:foo" requires "node" so that backend can run.
export def mise-backend-dependencies [
  path: path # Mise config file.
]: nothing -> list<record> {
  let tools = (tool-record $path)
  let keys = ($tools | columns)
  let dependencies = [
    {backend: npm tool: node prefix: "npm:"}
    {backend: cargo tool: rust prefix: "cargo:"}
    {backend: pipx tool: python prefix: "pipx:"}
  ]
  $dependencies | where {|dependency|
    ($keys | any {|key| $key | str starts-with $dependency.prefix }) and ($dependency.tool in $keys)
  }
}

# Backend-qualified tools whose host runtime is missing from [tools]; these
# would fail at install time and are reported as configuration errors.
export def mise-missing-backend-dependencies [
  path: path # Mise config file.
]: nothing -> list<record> {
  let tools = (tool-record $path)
  let keys = ($tools | columns)
  let dependencies = [
    {backend: npm tool: node prefix: "npm:"}
    {backend: cargo tool: rust prefix: "cargo:"}
    {backend: pipx tool: python prefix: "pipx:"}
  ]
  $dependencies | where {|dependency|
    ($keys | any {|key| $key | str starts-with $dependency.prefix }) and ($dependency.tool not-in $keys)
  }
}

# Resolve the mise config that owns global manager operations (the
# manager_config, defaulting to the first configured config).
export def mise-manager-config [
  root: path # Private state root.
  config: record # Loaded configuration.
]: nothing -> path {
  let settings = (($config.software? | default {}).mise? | default {})
  let configs = ($settings.configs? | default [])
  let relative = ($settings.manager_config? | default (if ($configs | is-empty) { "" } else { $configs | first }))
  if ($relative | describe) != "string" {
    error make {msg: "Mise manager_config must be a string when set"}
  }
  if ($relative | str trim | is-empty) {
    error make {msg: "A mise manager_config or at least one mise config is required"}
  }
  if $relative not-in $configs {
    error make {msg: $"Mise manager_config '($relative)' must be one of the selected configs: (($configs | str join ', '))"}
  }
  let selected = ($root | path join $relative)
  if not ($selected | path exists) {
    error make {msg: $"Mise manager_config does not exist: ($relative)"}
  }
  $selected
}

# Resolve the mise config exposed to interactive shells. It defaults to the
# manager config but remains an explicit selection so additional role or
# environment configs do not accidentally become global.
export def mise-shell-config [
  root: path # Private state root.
  config: record # Loaded configuration.
]: nothing -> path {
  let settings = (($config.software? | default {}).mise? | default {})
  let configs = ($settings.configs? | default [])
  let manager = ($settings.manager_config? | default (if ($configs | is-empty) { "" } else { $configs | first }))
  let relative = ($settings.shell_config? | default $manager)
  if ($relative | describe) != "string" {
    error make {msg: "Mise shell_config must be a string when set"}
  }
  if ($relative | str trim | is-empty) {
    error make {msg: "A mise shell_config, manager_config, or at least one mise config is required"}
  }
  if $relative not-in $configs {
    error make {msg: $"Mise shell_config '($relative)' must be one of the selected configs: (($configs | str join ', '))"}
  }
  let selected = ($root | path join $relative)
  if not ($selected | path exists) {
    error make {msg: $"Mise shell_config does not exist: ($relative)"}
  }
  $selected | path expand --no-symlink
}
