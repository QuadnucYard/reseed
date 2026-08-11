# Desired-state handling: base configuration loading with profile overlays
# (deep-merge), validation of every desired-state file, and state fingerprinting.

use core.nu [fail require-file state-sentinel-exists]
use mise.nu [mise-missing-backend-dependencies]
use ../integrations/managers/node/node_manager.nu [node-spec-parse]
use ../integrations/managers/uv.nu [uv-spec-parse]

# Merge the overlay record into the base record. Nested records merge
# recursively; every other value (including lists) replaces the base value.
export def deep-merge [
  base: record # Configuration to merge into.
  overlay: record # Values to apply on top.
]: nothing -> record {
  mut result = $base
  for entry in ($overlay | transpose key value) {
    let current = ($result | get -o $entry.key)
    let current_kind = if $current == null { "nothing" } else { $current | describe }
    let overlay_kind = ($entry.value | describe)
    let value = if ($current_kind | str starts-with "record") and ($overlay_kind | str starts-with "record") {
      deep-merge $current $entry.value
    } else {
      $entry.value
    }
    $result = ($result | upsert $entry.key $value)
  }
  $result
}

# Split a comma-separated profile list into trimmed, non-empty names.
export def parse-profiles [
  profiles: string # Comma-separated profile names; empty yields no profiles.
]: nothing -> list<string> {
  if ($profiles | str trim | is-empty) {
    []
  } else {
    $profiles | split row "," | each {|name| $name | str trim } | where {|name| not ($name | is-empty) }
  }
}

# True when a manager manifest entry is a non-empty string or a record with a
# non-empty string spec and an optional list of non-empty command strings.
def valid-manager-package-entry [entry: any]: nothing -> bool {
  let kind = ($entry | describe)
  if $kind == "string" {
    return (not (($entry | str trim) | is-empty))
  }
  if not ($kind | str starts-with "record") { return false }
  let spec = ($entry.spec? | default null)
  let commands = ($entry.commands? | default [])
  ($spec != null) and (($spec | describe) == "string") and not (($spec | str trim) | is-empty) and (($commands | describe) | str starts-with "list") and ($commands | all {|command| ($command | describe) == "string" and not (($command | str trim) | is-empty) })
}

# Load recovery.nuon and merge each selected profile overlay on top, recording
# the effective profile list in active_profiles.
export def load-config [
  root: path # Private state root.
  profiles: list<string> = [] # Profile names to merge; empty uses default_profiles.
]: nothing -> record {
  let base_path = ($root | path join "config" "recovery.nuon")
  require-file $base_path "base configuration"
  mut config = (open $base_path)
  if ($config | describe) !~ '^record' {
    fail $"Base configuration must be a NUON record: ($base_path)"
  }
  if ($config.schema? | default 0) != 1 {
    fail $"Unsupported configuration schema: ($config.schema? | default 'missing')"
  }

  let selected = if ($profiles | is-empty) {
    $config.default_profiles? | default []
  } else {
    $profiles
  }

  for profile in $selected {
    if $profile !~ '^[A-Za-z0-9][A-Za-z0-9_-]*$' {
      fail $"Invalid profile name: ($profile)"
    }
    let profile_path = ($root | path join "config" "profiles" $"($profile).nuon")
    require-file $profile_path $"profile '($profile)'"
    let overlay = (open $profile_path)
    if ($overlay | describe) !~ '^record' {
      fail $"Profile must contain a NUON record: ($profile_path)"
    }
    $config = (deep-merge $config $overlay)
  }

  $config | upsert active_profiles $selected
}

# Validate the private state and every desired-state file referenced by the
# configuration, returning one issue record per problem (no failures).
export def validate-config [
  root: path # Private state root.
  config: record # Loaded configuration.
]: nothing -> list<record> {
  [
    (validate-state-sentinel $root)
    (validate-software $root $config)
    (validate-chezmoi $root $config)
    (validate-setup $config)
    (validate-git $config)
  ] | flatten
}

# Validate the optional git section. Repository URLs stored in state are
# non-secret: HTTP credentials or tokens embedded in a git.url are rejected.
def validate-git [
  config: record # Loaded configuration.
]: nothing -> list<record> {
  let git = ($config.git? | default {})
  mut issues = []
  let remote = ($git.remote? | default null)
  if $remote != null and ((($remote | describe) != "string") or (($remote | str trim) | is-empty)) {
    $issues = ($issues | append {level: error area: git message: "git.remote must be a non-empty string"})
  }
  let branch = ($git.branch? | default null)
  if $branch != null and ((($branch | describe) != "string") or (($branch | str trim) | is-empty)) {
    $issues = ($issues | append {level: error area: git message: "git.branch must be a non-empty string"})
  }
  let url = ($git.url? | default null)
  if $url == null { return $issues }
  if (($url | describe) != "string") or (($url | str trim) | is-empty) {
    return ($issues | append {level: error area: git message: "git.url must be a non-empty repository URL"})
  }
  let scrubbed = ($url | str replace --regex '(?i)^https?://[^/@\s]+@' "")
  if $scrubbed != $url {
    return ($issues | append {level: error area: git message: "git.url must not embed credentials; keep repository URLs non-secret"})
  }
  let plausible = (($url | str starts-with "http://") or ($url | str starts-with "https://") or ($url | str starts-with "ssh://") or ($url | str starts-with "git://") or ($url | str contains "@"))
  if not $plausible {
    return ($issues | append {level: error area: git message: "git.url must be an http(s), ssh, git, or scp-style repository URL"})
  }
  $issues
}

# Issue when the private state root lacks the .reseed-state sentinel.
def validate-state-sentinel [
  root: path # Private state root.
]: nothing -> list<record> {
  if not (state-sentinel-exists $root) {
    [{level: error area: state message: "Private state is missing .reseed-state"}]
  } else {
    []
  }
}

# Issue when the source root is enabled for chezmoi but has no .chezmoiroot.
def validate-chezmoi [
  root: path # Private state root.
  config: record # Loaded configuration.
]: nothing -> list<record> {
  if (($config.chezmoi? | default {}).enabled? | default false) and not (($root | path join ".chezmoiroot") | path exists) {
    [{level: error area: chezmoi message: "The source is missing .chezmoiroot"}]
  } else {
    []
  }
}

# Validate the software section for every enabled manager (winget, homebrew,
# and mise with its cargo-binstall, uv, and Node manager extensions).
def validate-software [
  root: path # Private state root.
  config: record # Loaded configuration.
]: nothing -> list<record> {
  let software = ($config.software? | default {})
  mut issues = []
  for manager in [winget homebrew mise] {
    let settings = ($software | get -o $manager | default {})
    if ($settings.enabled? | default false) {
      $issues = ($issues | append (validate-desired-files $root $manager $settings))
      if $manager == "homebrew" {
        $issues = ($issues | append (validate-homebrew-settings $settings))
      }
      if $manager == "mise" {
        $issues = ($issues | append (validate-mise $root $settings))
      }
    }
  }
  let finder = ($software.finder_services? | default null)
  if $finder != null {
    if (($finder | describe) !~ '^record') {
      $issues = ($issues | append {level: error area: finder message: "software.finder_services must be a record with an enabled boolean"})
    } else {
      $issues = ($issues | append (validate-finder-settings $finder))
    }
  }
  $issues
}

# Validate the finder_services settings: the optional enabled flag must be a
# boolean. The section is absent by default and defaults to enabled.
def validate-finder-settings [
  settings: record # Finder services settings.
]: nothing -> list<record> {
  let enabled = ($settings.enabled? | default null)
  if $enabled != null and (($enabled | describe) != "bool") {
    return [{level: error area: finder message: "software.finder_services.enabled must be a boolean"}]
  }
  []
}

# Validate the Homebrew settings: the optional env record (used to route
# brew, taps, and bottles through a mirror) must contain string values.
def validate-homebrew-settings [
  settings: record # Homebrew manager settings.
]: nothing -> list<record> {
  let environment = ($settings.env? | default null)
  if $environment == null { return [] }
  if (($environment | describe) !~ '^record') {
    return [{level: error area: homebrew message: "software.homebrew.env must be a record of environment variable names to values"}]
  }
  let invalid = ($environment | transpose key value | where {|entry| ($entry.value | describe) != "string" })
  if ($invalid | is-not-empty) {
    return [{level: error area: homebrew message: $"software.homebrew.env values must be strings; fix: (($invalid | get key | str join ', '))"}]
  }
  let invalid_names = ($environment | columns | where {|name| $name !~ '^[A-Za-z_][A-Za-z0-9_]*$' })
  if ($invalid_names | is-not-empty) {
    return [{level: error area: homebrew message: $"software.homebrew.env names must be valid environment variable names; fix: (($invalid_names | str join ', '))"}]
  }
  []
}

# Validate existence (and, for winget and mise, the shape) of every
# desired-state file a manager lists under manifests or configs.
def validate-desired-files [
  root: path # Private state root.
  manager: string # Manager name used for messaging.
  settings: record # Manager settings record.
]: nothing -> list<record> {
  let key = if $manager == "mise" { "configs" } else { "manifests" }
  mut issues = []
  for relative in ($settings | get -o $key | default []) {
    let target = ($root | path join $relative)
    if not ($target | path exists) {
      $issues = ($issues | append {level: error area: $manager message: $"Missing desired-state file: ($relative)"})
    }
    if $manager == "winget" and ($target | path exists) {
      $issues = ($issues | append (validate-winget-manifest $target $relative))
    }
    if $manager == "mise" {
      let name = ($target | path basename)
      if ($name != "mise.toml") and ($name !~ '^mise\.[A-Za-z0-9_-]+\.toml$') {
        $issues = ($issues | append {level: error area: mise message: $"Unsupported config name: ($relative); use mise.toml or mise.<environment>.toml"})
      }
    }
  }
  $issues
}

# Validate that a WinGet export file parses as JSON and that every source
# lists packages with string PackageIdentifier values.
def validate-winget-manifest [
  target: path # WinGet export file.
  relative: string # Path relative to the state root, for messaging.
]: nothing -> list<record> {
  let parsed = (try {
    {ok: true manifest: (open $target)}
  } catch {|error|
    {ok: false detail: ($error.msg? | default ($error | to nuon))}
  })
  if not $parsed.ok {
    return [{level: error area: winget message: $"Invalid WinGet manifest '($relative)': ($parsed.detail)"}]
  }
  if (($parsed.manifest | describe) !~ '^record') {
    return [{level: error area: winget message: $"WinGet manifest must be a JSON object: ($relative)"}]
  }
  let sources = ($parsed.manifest.Sources? | default null)
  let sources_kind = if $sources == null { "nothing" } else { $sources | describe }
  if $sources == null or not (($sources_kind | str starts-with "list") or ($sources_kind | str starts-with "table")) {
    return [{level: error area: winget message: $"WinGet manifest Sources must be a list: ($relative)"}]
  }
  mut issues = []
  for source in $sources {
    let packages = ($source.Packages? | default null)
    let packages_kind = if $packages == null { "nothing" } else { $packages | describe }
    if $packages == null or not (($packages_kind | str starts-with "list") or ($packages_kind | str starts-with "table")) or not ($packages | all {|package| ($package.PackageIdentifier? | default null) != null and (($package.PackageIdentifier? | default null | describe) == "string") }) {
      $issues = ($issues | append {level: error area: winget message: $"WinGet source packages must contain string PackageIdentifier values: ($relative)"})
    }
  }
  $issues
}

# Names of the tools declared in a mise config [tools] table, with any
# backend-qualified prefix (e.g. "aqua:pnpm/pnpm") reduced to the bare tool
# name ("pnpm"). Returns an empty list when the file is missing or unparsable.
def mise-config-tool-names [
  path: path # Mise config file.
]: nothing -> list<string> {
  if not ($path | path exists) { return [] }
  let manifest = (try { open $path } catch { return [] })
  let tools = ($manifest.tools? | default {})
  if not (($tools | describe) | str starts-with "record") { return [] }
  $tools | columns | each {|key|
    let name = (if ($key | str contains ":") {
      $key | str substring (($key | str index-of ":") + 1)..
    } else { $key })
    $name | split row "/" | last
  }
}

# The mise tool every enabled manager integration expects so its commands run
# through "mise exec -- <tool>"; the aqua key is the recommended declaration.
def manager-bootstrap-tools []: nothing -> list<record> {
  [
    {manager: cargo_binstall tool: "cargo-binstall" aqua: "aqua:cargo-bins/cargo-binstall"}
    {manager: uv tool: "uv" aqua: "aqua:astral-sh/uv"}
    {manager: pnpm tool: "pnpm" aqua: "aqua:pnpm/pnpm"}
    {manager: yarn tool: "yarn" aqua: "aqua:yarnpkg/yarn"}
    {manager: bun tool: "bun" aqua: "aqua:oven-sh/bun"}
  ]
}

# Validate the mise settings: manager config selection, backend dependencies,
# task files, and the nested cargo-binstall, uv, and Node manager sections.
def validate-mise [
  root: path # Private state root.
  settings: record # Mise manager settings.
]: nothing -> list<record> {
  mut issues = []
  let manager_config = ($settings.manager_config? | default (if (($settings.configs? | default []) | is-empty) { "" } else { $settings.configs | first }))
  let configured_configs = ($settings.configs? | default [])
  if ($manager_config | describe) != "string" {
    $issues = ($issues | append {level: error area: mise message: "software.mise.manager_config must be a string when set"})
  } else if ($manager_config | str trim | is-empty) {
    $issues = ($issues | append {level: error area: mise message: "manager_config or at least one mise config is required"})
  } else if $manager_config not-in $configured_configs {
    $issues = ($issues | append {level: error area: mise message: $"Mise manager_config '($manager_config)' must be one of the selected configs: (($configured_configs | str join ', '))"})
  }
  let shell_config = ($settings.shell_config? | default $manager_config)
  if ($shell_config | describe) != "string" {
    $issues = ($issues | append {level: error area: mise message: "software.mise.shell_config must be a string when set"})
  } else if ($shell_config | str trim | is-empty) {
    $issues = ($issues | append {level: error area: mise message: "shell_config, manager_config, or at least one mise config is required"})
  } else if $shell_config not-in $configured_configs {
    $issues = ($issues | append {level: error area: mise message: $"Mise shell_config '($shell_config)' must be one of the selected configs: (($configured_configs | str join ', '))"})
  }
  let shell_task = ($settings.shell_task? | default null)
  if $shell_task != null and ((($shell_task | describe) != "string") or (($shell_task | str trim) | is-empty)) {
    $issues = ($issues | append {level: error area: mise message: "software.mise.shell_task must be a non-empty string when set"})
  }
  # Backend dependencies are only checked when every config file exists;
  # missing files are already reported by validate-desired-files.
  let all_configs_exist = ($configured_configs | all {|relative| ($root | path join $relative) | path exists })
  if $all_configs_exist {
    for relative in $configured_configs {
      for dependency in (mise-missing-backend-dependencies ($root | path join $relative)) {
        $issues = ($issues | append {
          level: error
          area: mise
          message: $"Mise backend '($dependency.backend)' in ($relative) requires '($dependency.tool)' in the same [tools] table; add ($dependency.tool) = \"latest\" or remove the backend-qualified entry"
        })
      }
    }
  }
  # Manager operations run "mise exec -- <tool>" through the manager config, so
  # an enabled manager needs its tool declared there to be reproducible. The
  # engine still falls back to the ambient PATH, so this is advisory: a warning
  # points at the exact [tools] entry before verification fails opaquely.
  let manager_config_path = if (($manager_config | describe) == "string") and (not ($manager_config | str trim | is-empty)) {
    $root | path join $manager_config
  } else {
    null
  }
  if $manager_config_path != null and ($manager_config_path | path exists) {
    let declared_tools = (mise-config-tool-names $manager_config_path)
    for tool in (manager-bootstrap-tools) {
      let enabled = (($settings | get -o $tool.manager | default {}).enabled? | default false)
      if $enabled and ($tool.tool not-in $declared_tools) {
        $issues = ($issues | append {
          level: warning
          area: $tool.manager
          message: $"software.mise.($tool.manager) is enabled but ($tool.tool) is not declared in ($manager_config); add ($tool.aqua) = \"latest\" to [tools] so 'mise exec -- ($tool.tool)' can run it"
        })
      }
    }
  }
  for relative in ($settings.task_files? | default []) {
    if not (($root | path join $relative) | path exists) {
      $issues = ($issues | append {level: error area: mise message: $"Missing mise task file: ($relative)"})
    }
  }
  $issues = ($issues | append (validate-cargo-binstall $root $settings))
  $issues = ($issues | append (validate-package-managers $root $settings))
  $issues
}

# Validate the cargo-binstall section: a manifest is required when enabled,
# and each manifest must exist with schema 1 and a list of string packages.
def validate-cargo-binstall [
  root: path # Private state root.
  settings: record # Mise manager settings.
]: nothing -> list<record> {
  let cargo_binstall = ($settings.cargo_binstall? | default {})
  if not ($cargo_binstall.enabled? | default false) { return [] }
  let manifests = ($cargo_binstall.manifests? | default [])
  if ($manifests | is-empty) {
    return [{level: error area: cargo-binstall message: "At least one cargo-binstall manifest is required when enabled"}]
  }
  mut issues = []
  for relative in $manifests {
    let target = ($root | path join $relative)
    if not ($target | path exists) {
      $issues = ($issues | append {level: error area: cargo-binstall message: $"Missing desired-state file: ($relative)"})
    } else {
      let manifest = (open $target)
      if ($manifest.schema? | default 0) != 1 {
        $issues = ($issues | append {level: error area: cargo-binstall message: $"Unsupported manifest schema: ($relative)"})
      }
      let packages = ($manifest.packages? | default null)
      if $packages == null or not (($packages | describe) | str starts-with "list") or not ($packages | all {|package| ($package | describe) == "string" }) {
        $issues = ($issues | append {level: error area: cargo-binstall message: $"Manifest packages must be a list: ($relative)"})
      }
    }
  }
  $issues
}

# Validate the uv, pnpm, yarn, and bun sections: a manifest is required when a
# manager is enabled, each manifest must parse, and every package specifier
# must be supported by the owning manager.
def validate-package-managers [
  root: path # Private state root.
  settings: record # Mise manager settings.
]: nothing -> list<record> {
  mut issues = []
  for manager in [uv pnpm yarn bun] {
    let manager_settings = ($settings | get -o $manager | default {})
    if not ($manager_settings.enabled? | default false) { continue }
    let manifests = ($manager_settings.manifests? | default [])
    if ($manifests | is-empty) {
      $issues = ($issues | append {level: error area: $manager message: $"At least one ($manager) manifest is required when enabled"})
    }
    let spec_hint = if $manager == "uv" { "name==version" } else { "name@version" }
    for relative in $manifests {
      let target = ($root | path join $relative)
      if not ($target | path exists) {
        $issues = ($issues | append {level: error area: $manager message: $"Missing desired-state file: ($relative)"})
      } else {
        $issues = ($issues | append (validate-manager-manifest $target $relative $manager $spec_hint))
      }
    }
  }
  $issues
}

# Validate one uv/pnpm/yarn/bun manifest: schema 1, package entries with the
# required shape, and package specifiers the manager can parse.
def validate-manager-manifest [
  target: path # Manifest file.
  relative: string # Path relative to the state root, for messaging.
  manager: string # Manager name.
  spec_hint: string # Example specifier shape for error messages.
]: nothing -> list<record> {
  let manifest = (open $target)
  if ($manifest.schema? | default 0) != 1 {
    return [{level: error area: $manager message: $"Unsupported manifest schema: ($relative)"}]
  }
  let packages = ($manifest.packages? | default null)
  let packages_kind = if $packages == null { "nothing" } else { $packages | describe }
  if $packages == null or not (($packages_kind | str starts-with "list") or ($packages_kind | str starts-with "table")) or not ($packages | all {|package| valid-manager-package-entry $package }) {
    return [{level: error area: $manager message: $"Manifest packages must contain strings or records with a non-empty spec and optional command list: ($relative)"}]
  }
  mut issues = []
  for package in $packages {
    let spec = if ($package | describe) == "string" { $package } else { $package.spec }
    let supported = if $manager == "uv" {
      (uv-spec-parse $spec) != null
    } else {
      (node-spec-parse $spec) != null
    }
    if not $supported {
      $issues = ($issues | append {level: error area: $manager message: $"Unsupported package specifier '($spec)' in ($relative); use name or ($spec_hint)"})
    }
  }
  $issues
}

# Validate the optional setup section: SSH host entries must carry a user and
# host, with optional numeric port, boolean admin flag, and a supported
# host operating system.
def validate-setup [
  config: record # Loaded configuration.
]: nothing -> list<record> {
  let hosts = ((($config.setup? | default {}).ssh? | default {}).hosts? | default null)
  if $hosts == null { return [] }
  let hosts_kind = ($hosts | describe)
  if not (($hosts_kind | str starts-with "list") or ($hosts_kind | str starts-with "table")) {
    return [{level: error area: setup message: "setup.ssh.hosts must be a list of host records"}]
  }
  mut issues = []
  for host in $hosts {
    if ($host | describe) !~ '^record' {
      $issues = ($issues | append {level: error area: setup message: "setup.ssh.hosts entries must be records with user and host"})
      continue
    }
    let user = ($host.user? | default "")
    let hostname = ($host.host? | default "")
    if (($user | describe) != "string") or (($user | str trim) | is-empty) {
      $issues = ($issues | append {level: error area: setup message: $"Setup host requires a non-empty user: (($host | to nuon))"})
    }
    if (($hostname | describe) != "string") or (($hostname | str trim) | is-empty) {
      $issues = ($issues | append {level: error area: setup message: $"Setup host requires a non-empty host: (($host | to nuon))"})
    }
    let port = ($host.port? | default null)
    if $port != null and (($port | describe) != "int") {
      $issues = ($issues | append {level: error area: setup message: $"Setup host port must be an integer: (($host | to nuon))"})
    }
    let admin = ($host.admin? | default null)
    if $admin != null and (($admin | describe) != "bool") {
      $issues = ($issues | append {level: error area: setup message: $"Setup host admin must be a boolean: (($host | to nuon))"})
    }
    let os = ($host.os? | default null)
    if $os != null and ((($os | describe) != "string") or ($os not-in ["windows" "macos" "unix"])) {
      $issues = ($issues | append {level: error area: setup message: $"Setup host os must be windows, macos, or unix: (($host | to nuon))"})
    }
  }
  $issues
}

# Hash the configuration together with every desired-state file it references.
# The path of each file is included so a rename invalidates the fingerprint
# even when the contents are unchanged.
export def config-fingerprint [
  root: path # Private state root.
  config: record # Loaded configuration.
  --engine-root: path # Engine directory; includes engine files when given.
]: nothing -> string {
  let files = ([
    (fingerprint-state-files $root $config)
    (fingerprint-directory-files ($root | path join "home"))
    (fingerprint-engine-files $engine_root)
  ] | flatten | uniq | sort | where {|path| $path | path exists })
  let content = ($files | each {|path| $"($path):((open --raw $path | hash sha256))" } | str join "\n")
  $"($config | to nuon)\n($content)" | hash sha256
}

# Desired-state files referenced directly by the configuration: base config,
# profile overlays, native manifests, mise configs and task files, and the
# nested manager manifests.
def fingerprint-state-files [
  root: path # Private state root.
  config: record # Loaded configuration.
]: nothing -> list<path> {
  mut files = [($root | path join "config" "recovery.nuon") ($root | path join ".chezmoiroot")]
  for profile in ($config.active_profiles? | default []) {
    $files = ($files | append ($root | path join "config" "profiles" $"($profile).nuon"))
  }
  let software = ($config.software? | default {})
  for manager in [winget homebrew mise] {
    let settings = ($software | get -o $manager | default {})
    let key = if $manager == "mise" { "configs" } else { "manifests" }
    for relative in ($settings | get -o $key | default []) {
      $files = ($files | append ($root | path join $relative))
    }
    if $manager == "mise" {
      for relative in ($settings.task_files? | default []) {
        $files = ($files | append ($root | path join $relative))
      }
      for relative in (($settings.cargo_binstall? | default {}).manifests? | default []) {
        $files = ($files | append ($root | path join $relative))
      }
      for manager in [uv pnpm yarn bun] {
        let manager_settings = ($settings | get -o $manager | default {})
        for relative in ($manager_settings.manifests? | default []) {
          $files = ($files | append ($root | path join $relative))
        }
      }
    }
  }
  $files
}

# Every regular file under a directory, or [] when the directory is absent.
def fingerprint-directory-files [
  root: path # Directory to scan.
]: nothing -> list<path> {
  if not ($root | path exists) { return [] }
  do { cd $root; glob **/* --no-dir | each {|relative| $root | path join $relative } }
}

# The engine's own scripts (entrypoint, bootstraps, and everything under lib/
# and integrations/) that affect restore behavior.
def fingerprint-engine-files [
  engine_root: any # Engine directory; null when unavailable.
]: nothing -> list<path> {
  if $engine_root == null { return [] }
  mut files = [
    ($engine_root | path join "reseed.nu")
    ($engine_root | path join "bootstrap.ps1")
    ($engine_root | path join "bootstrap.sh")
  ]
  for directory in [lib integrations] {
    $files = ($files | append (fingerprint-directory-files ($engine_root | path join $directory)))
  }
  # Platform feature templates (e.g. the macOS Finder Quick Actions) affect
  # what restore writes, so they belong to the engine fingerprint too.
  $files = ($files | append (fingerprint-directory-files ($engine_root | path join "templates" "macos")))
  $files
}
