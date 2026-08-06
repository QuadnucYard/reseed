use ../lib/prelude.nu *
use bootstrap.nu [bootstrap-brew-items]

# Declared entries of a Brewfile (brew/cask/tap/mas/vscode lines), with
# trailing comments stripped.
export def brewfile-items [
  path: path # Brewfile path.
]: nothing -> list<string> {
  if not ($path | path exists) { return [] }
  open --raw $path
    | lines
    | each {|line| $line | str trim }
    | where {|line| ($line =~ '^(brew|cask|tap|mas|vscode)\s+"') }
    | each {|line| $line | str replace --regex '\s*#.*$' '' }
    | uniq
    | sort
}

# Brewfile entries excluding the bootstrap-contract tools the engine installs
# itself.
export def native-brewfile-items [
  path: path # Brewfile path.
]: nothing -> list<string> {
  brewfile-items $path | where {|item| $item not-in (bootstrap-brew-items) }
}

# Availability and desired-manifest health for the Homebrew integration.
export def homebrew-status [
  root: path # Private state root.
  config: record # Loaded configuration.
]: nothing -> record {
  let settings = $config.software.homebrew
  let manifests = ($settings.manifests? | default [])
  {
    tool: homebrew
    enabled: ($settings.enabled? | default false)
    applicable: ((detect-os) == "macos")
    available: (command-exists brew)
    desired: ($manifests | each {|item| {path: $item exists: (($root | path join $item) | path exists)} })
  }
}

# Install every configured Brewfile.
export def homebrew-restore [
  root: path # Private state root.
  config: record # Loaded configuration.
  --dry-run # Show the installs without running them.
] {
  let settings = $config.software.homebrew
  if not ($settings.enabled? | default false) or ((detect-os) != "macos") { return }
  if not (command-exists brew) and not $dry_run { error make {msg: "Homebrew is required for the macOS package stage"} }
  for manifest in ($settings.manifests? | default []) {
    let path = ($root | path join $manifest)
    run-command brew ["bundle" "install" $"--file=($path)"] --dry-run=$dry_run | ignore
  }
}

# Update Homebrew and upgrade only the packages each Brewfile declares,
# excluding the bootstrap-contract tools.
export def homebrew-update [
  root: path # Private state root.
  config: record # Loaded configuration.
  --dry-run # Show the updates without running them.
] {
  let settings = $config.software.homebrew
  if not ($settings.enabled? | default false) or not ($settings.update? | default true) or ((detect-os) != "macos") { return }
  if not (command-exists brew) { warning "Homebrew is unavailable; skipping macOS package updates"; return }
  run-command brew ["update"] --dry-run=$dry_run | ignore
  for manifest in ($settings.manifests? | default []) {
    let path = ($root | path join $manifest)
    run-command brew ["bundle" "install" $"--file=($path)"] --dry-run=$dry_run | ignore
    for kind in [brews casks] {
      upgrade-brewfile-kind $path $kind --dry-run=$dry_run
    }
  }
}

# Upgrade one kind of package (brews or casks) declared in a Brewfile,
# skipping anything the bootstrap contract owns.
def upgrade-brewfile-kind [
  path: path # Brewfile path.
  kind: string # "brews" or "casks".
  --dry-run # Show the upgrades without running them.
] {
  let listed = (run-command brew ["bundle" "list" $"--file=($path)" $"--($kind)"] --allow-failure --dry-run=$dry_run)
  if ($listed.exit_code != 0) or $dry_run { return }
  let names = ($listed.stdout | lines | each {|line| $line | str trim } | compact)
  let ignored_names = (bootstrap-brew-items
    | parse --regex '^(?:brew|cask)\s+"(?<name>[^"]+)"'
    | get -o name
    | default [])
  let names = ($names | where {|name| $name not-in $ignored_names })
  if ($names | is-not-empty) {
    let args = if $kind == "casks" { ["upgrade" "--cask"] | append $names } else { ["upgrade"] | append $names }
    let upgraded = (run-command brew $args --allow-failure)
    if $upgraded.exit_code != 0 { warning $"Some Homebrew ($kind) updates failed: ($upgraded.stderr | str trim)" }
  }
}

# True when a Brewfile line is one of the bootstrap-contract entries.
def bootstrap-brew-line? [
  line: string # Brewfile line.
]: nothing -> bool {
  let normalized = ($line | str replace --regex '\s*#.*$' '' | str trim)
  $normalized in (bootstrap-brew-items)
}

# Remove the bootstrap-contract entries from a Brewfile in place.
def filter-bootstrap-brew-items [
  path: path # Brewfile path to rewrite.
] {
  let lines = (open --raw $path | lines | where {|line| not (bootstrap-brew-line? $line) })
  ($lines | str join "\n") | save --force $path
}

# Export the installed formulas and casks to a Brewfile, optionally filtering
# out the bootstrap tools. Export failures degrade to a warning.
def export-brewfile [
  path: path # Destination Brewfile path.
  --exclude-bootstrap # Filter engine-owned entries from the export.
  --dry-run # Show the export without running it.
]: nothing -> bool {
  if $dry_run {
    run-command brew ["bundle" "dump" $"--file=($path)" "--force"] --dry-run | ignore
    return true
  }
  mkdir ($path | path dirname)
  let result = (run-command brew ["bundle" "dump" $"--file=($path)" "--force"] --allow-failure)
  if $result.exit_code != 0 {
    warning $"Brewfile export failed: ($result.stderr | str trim)"
    false
  } else {
    if $exclude_bootstrap { filter-bootstrap-brew-items $path }
    true
  }
}

# Capture the Homebrew inventory. With --refresh-manifests the single
# configured Brewfile is replaced by the live dump; otherwise the dump is
# written as an observation under the disposable state directory.
export def homebrew-backup [
  root: path # Private state root.
  config: record # Loaded configuration.
  --refresh-manifests # Replace the curated Brewfile with the live dump.
  --dry-run # Show the dump without running it.
] {
  let settings = $config.software.homebrew
  if not ($settings.enabled? | default false) or ((detect-os) != "macos") or not (command-exists brew) { return }
  let refresh = $refresh_manifests or ($settings.export_on_backup? | default false)
  let target = if $refresh and (($settings.manifests? | default [] | length) == 1) {
    $root | path join ($settings.manifests | first)
  } else {
    if $refresh { warning "Homebrew refresh requires exactly one target Brewfile; writing an observation instead" }
    observation-dir $config | path join "Brewfile"
  }
  export-brewfile $target --exclude-bootstrap=$refresh --dry-run=$dry_run | ignore
  if not $refresh { info $"Homebrew observation: ($target)" }
}

# Compare the curated Brewfiles with a fresh dump, report-only.
export def homebrew-reconcile [
  root: path # Private state root.
  config: record # Loaded configuration.
  --dry-run # Skip the live dump.
]: nothing -> record {
  let settings = $config.software.homebrew
  if not ($settings.enabled? | default false) or ((detect-os) != "macos") {
    return {tool: homebrew applicable: false desired_only: [] observed_only: []}
  }
  if not (command-exists brew) {
    return {tool: homebrew applicable: true error: "brew is unavailable" desired_only: [] observed_only: []}
  }
  let observed = (observation-dir $config | path join "Brewfile")
  if not (export-brewfile $observed --dry-run=$dry_run) or $dry_run {
    return {tool: homebrew applicable: true observation: $observed desired_only: [] observed_only: []}
  }
  let desired = ($settings.manifests? | default [] | each {|manifest| native-brewfile-items ($root | path join $manifest) } | flatten | uniq | sort)
  let current = (native-brewfile-items $observed)
  {
    tool: homebrew
    applicable: true
    observation: $observed
    desired_only: ($desired | where {|item| $item not-in $current })
    observed_only: ($current | where {|item| $item not-in $desired })
  }
}

# Verification checks for Homebrew: executable presence, Brewfile health, and
# that every declared package is installed.
export def homebrew-verify [
  root: path # Private state root.
  config: record # Loaded configuration.
]: nothing -> list<record> {
  let settings = $config.software.homebrew
  if not ($settings.enabled? | default false) or ((detect-os) != "macos") { return [] }
  mut results = [{check: "homebrew executable" ok: (command-exists brew) detail: "required on macOS"}]
  for manifest in ($settings.manifests? | default []) {
    let path = ($root | path join $manifest)
    $results = ($results | append {check: $"Brewfile: ($manifest)" ok: ($path | path exists) detail: $"((brewfile-items $path | length)) entries"})
    if (command-exists brew) and ($path | path exists) {
      let checked = (try {
        run-command brew ["bundle" "check" $"--file=($path)"] --allow-failure
      } catch {|error| {exit_code: 1 stdout: "" stderr: ($error.msg? | default "failed to start brew")} })
      $results = ($results | append {
        check: $"Homebrew packages installed: ($manifest)"
        ok: ($checked.exit_code == 0)
        detail: (if $checked.exit_code == 0 { "complete" } else { ($checked.stdout + $checked.stderr | str trim) })
      })
    }
  }
  $results
}
