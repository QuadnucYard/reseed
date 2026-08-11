# Orchestration layer composing the lib modules and integrations into the
# reseed workflows: init, plan, status, restore, backup, update, reconcile,
# verify, and bundle.

use core.nu [command-exists confirm detect-os fail info run-command state-sentinel-exists warning]
use config.nu [config-fingerprint load-config validate-config]
use state.nu [complete-stage fail-stage load-checkpoint stage-done]
use git.nu [git-bundle git-commit git-init git-pull git-status git-sync]
use secrets.nu [commit-change-summary scan-commit-secrets]
use ../integrations/chezmoi.nu [chezmoi-backup chezmoi-restore chezmoi-status chezmoi-verify]
use ../integrations/bootstrap.nu [bootstrap-outdated bootstrap-status bootstrap-verify]
use ../integrations/finder.nu [finder-backup finder-enabled finder-reconcile finder-restore finder-status finder-verify]
use ../integrations/homebrew.nu [homebrew-backup homebrew-persist-env homebrew-reconcile homebrew-restore homebrew-status homebrew-update homebrew-verify]
use ../integrations/kopia.nu [kopia-backup kopia-restore kopia-status kopia-verify]
use ../integrations/mise.nu [mise-configure-shells mise-reconcile mise-restore mise-status mise-update mise-verify]
use ../integrations/tooling.nu [tooling-backup tooling-observe]
use ../integrations/winget.nu [winget-backup winget-reconcile winget-restore winget-status winget-update winget-verify]

# Names of the tools verified in the final restore stage. --skip-software
# excludes the native package managers and mise; the bootstrap contract,
# chezmoi, and kopia are always verified.
export def workflow-verification-tools [
  --skip-software # Exclude native packages and mise-managed tools.
]: nothing -> list<string> {
  let software = if $skip_software { [] } else { [winget homebrew mise] }
  [bootstrap] | append $software | append [chezmoi kopia finder]
}

# Directory of the generic state template shipped with the engine.
def state-template [
  engine_root: path # Engine directory.
]: nothing -> path {
  $engine_root | path join "templates" "state"
}

# True when the state root is not a repository or has no commits yet, i.e. it
# is a template scaffold rather than committed private state.
def state-uncommitted [
  state_root: path # Private state root.
]: nothing -> bool {
  if not (command-exists git) { return true }
  let probe = (run-command git ["-C" ($state_root | into string) "rev-parse" "--verify" "HEAD"] --allow-failure --quiet --capture)
  $probe.exit_code != 0
}

# Copy template files missing from an already-initialized state root, so a
# partial or interrupted seed (for example one lacking config/recovery.nuon)
# still runs setup and restore. Never overwrites existing files; the home/
# chezmoi source, which is applied to the machine, is left alone. Existing
# directories are recursed into so missing nested files are healed too.
def seed-missing-files [
  template: path # Engine state template.
  state_root: path # Private state root.
  --dry-run # Report the copies without writing them.
] {
  for entry in (ls --all $template) {
    let relative = ($entry.name | path basename)
    if $relative == "home" { continue }
    let target = ($state_root | path join $relative)
    if ($entry.type == dir) {
      if not ($target | path exists) {
        if $dry_run {
          info $"would seed template file to state: ($relative)"
        } else {
          cp --recursive $entry.name $target
          info $"seeded template file to state: ($relative)"
        }
      } else {
        seed-missing-files $entry.name $target --dry-run=$dry_run
      }
    } else if not ($target | path exists) {
      if $dry_run {
        info $"would seed template file to state: ($relative)"
      } else {
        cp --recursive $entry.name $target
        info $"seeded template file to state: ($relative)"
      }
    }
  }
}

# Seed the private state root from the engine template. Refuses a nonempty
# directory without the sentinel. An initialized root that has no commits (a
# template scaffold) is re-seeded for any missing template files so an
# incomplete seed repairs itself; committed private state is left untouched.
def ensure-state-root [
  engine_root: path # Engine directory providing the template.
  state_root: path # Private state root to seed.
  --dry-run # Report the seeding without copying.
] {
  let template = (state-template $engine_root)
  if not ($template | path exists) { fail $"State template is missing: ($template)" }
  if ($state_root | path exists) {
    let entries = (ls --all $state_root)
    if ($entries | is-not-empty) and not (state-sentinel-exists $state_root) {
      fail $"Refusing nonempty directory without .reseed-state: ($state_root)"
    }
    if (state-sentinel-exists $state_root) {
      if (state-uncommitted $state_root) {
        seed-missing-files $template $state_root --dry-run=$dry_run
      }
      return
    }
  }

  if $dry_run {
    info $"would seed private state from ($template) to ($state_root)"
    return
  }
  mkdir $state_root
  for entry in (ls --all $template) {
    cp --recursive $entry.name $state_root
  }
}

# Engine-owned template files that are copied into existing state repositories
# when missing, so repositories seeded before the file existed (or that lost it)
# stay runnable. Only add-if-missing: user edits are never overwritten.
def engine-owned-files [
  engine_root: path # Engine directory providing the template.
]: nothing -> list<path> {
  [
    ($engine_root | path join "templates" "state" "scripts" "configure-shells.nu")
  ]
}

# Copy missing engine-owned template files into an existing state repository.
# A missing shell generator would otherwise fail desired-state validation, so
# this runs before check-config in restore and update and on every re-runnable
# init. Existing copies are left untouched so user customizations survive.
export def sync-engine-files [
  engine_root: path # Engine directory providing the template.
  state_root: path # Private state root.
  --dry-run # Report the copies without writing them.
] {
  let template_root = ($engine_root | path join "templates" "state")
  for template in (engine-owned-files $engine_root) {
    let relative = ($template | path relative-to $template_root)
    let target = ($state_root | path join $relative)
    if ($template | path exists) and not ($target | path exists) {
      if $dry_run {
        info $"would seed engine-owned file to state: ($relative)"
      } else {
        mkdir ($target | path dirname)
        cp $template $target
        info $"seeded engine-owned file to state: ($relative)"
      }
    }
  }
}

# Create or validate the private state repository and initialize Git.
export def workflow-init [
  engine_root: path # Engine directory.
  state_root: path # Private state root.
  profiles: list<string> # Profile names to validate against.
  --remote-url: string # Private Git remote URL to configure as origin.
  --dry-run # Show what would be initialized without writing files.
] {
  ensure-state-root $engine_root $state_root --dry-run=$dry_run
  sync-engine-files $engine_root $state_root --dry-run=$dry_run
  let config_root = if (state-sentinel-exists $state_root) { $state_root } else { state-template $engine_root }
  let config = (load-config $config_root $profiles)
  check-config $config_root $config
  git-init $state_root $config --remote-url=$remote_url --dry-run=$dry_run
  if not $dry_run and ($remote_url != null) and not ($remote_url | str trim | is-empty) {
    # Attaching a remote to an existing root now adopts its state when safe, so
    # the documented "attach a private remote" flow actually pulls the private
    # state in instead of leaving the local scaffold in place. A dirty or
    # diverged root is left alone (warning) so recovery is never blocked; use
    # "reseed adopt" for an explicit, replace-capable link.
    let adopted = (git-sync $state_root $remote_url)
    if not $adopted.synced {
      warning $"Attached the remote but left the local state unchanged: ($adopted.status). Run 'reseed adopt --remote-url ... --replace' to replace it."
    }
  }
  info $"Private Reseed state: ($state_root)"
}

# Ordered recovery stages with their owners and whether each is enabled for
# the current platform and configuration.
export def workflow-plan [
  root: path # Private state root.
  config: record # Loaded configuration.
  --skip-software # Exclude native packages and mise-managed tools.
]: nothing -> list<record> {
  let os = (detect-os)
  let winget = (winget-status $root $config)
  let brew = (homebrew-status $root $config)
  let mise = (mise-status $root $config)
  let chezmoi = (chezmoi-status $root $config)
  let kopia = (kopia-status $config)
  [
    {order: 1 stage: system-packages enabled: ((not $skip_software) and (($os == "windows" and $winget.enabled) or ($os == "macos" and $brew.enabled))) owner: (if $os == "windows" { "winget" } else if $os == "macos" { "homebrew" } else { "unsupported" })}
    {order: 2 stage: portable-tools enabled: ((not $skip_software) and $mise.enabled) owner: mise}
    {order: 3 stage: macos-finder enabled: (($os == "macos") and (finder-enabled $config)) owner: finder}
    {order: 4 stage: configuration enabled: $chezmoi.enabled owner: chezmoi}
    {order: 5 stage: snapshots enabled: ($kopia.enabled and ($kopia.restores > 0)) owner: kopia}
    {order: 6 stage: verification enabled: true owner: reseed}
  ]
}

# Warn about outdated bootstrap tools; advisory only.
def warn-bootstrap-outdated [
  outdated: list<record> # Outdated bootstrap tools.
] {
  if ($outdated | is-empty) { return }
  warning $"Outdated bootstrap tools: (($outdated | each {|tool| $'($tool.command) ($tool.version) -> ($tool.latest)' }) | str join ', ')"
  info "Upgrade them by rerunning the platform bootstrap with --update-tools"
}

# Report integration availability, private repository state, and desired-state
# file health as tables.
export def workflow-status [
  root: path # Private state root.
  config: record # Loaded configuration.
] {
  info $"platform: (detect-os)"
  info $"private state: ($root)"
  info $"profiles: ($config.active_profiles | str join ', ')"
  let git = (git-status $root)
  let bootstrap = (bootstrap-status)
  let outdated = (bootstrap-outdated)
  let outdated_names = (if ($outdated | is-empty) { null } else { $outdated | get name })
  [
    ({tool: bootstrap enabled: true applicable: true available: (($bootstrap | where available == false | is-empty)) outdated: $outdated_names desired: ($bootstrap | each {|item| {command: $item.command available: $item.available} })})
    (chezmoi-status $root $config)
    (winget-status $root $config)
    (homebrew-status $root $config)
    (finder-status $root $config)
    (mise-status $root $config)
    (kopia-status $config)
    ({tool: git enabled: true applicable: true available: $git.available repository: $git.repository clean: $git.clean})
  ] | table --expand | print

  let issues = (validate-config $root $config)
  if ($issues | is-empty) { info "desired-state files are present" } else { $issues | table | print }
  warn-bootstrap-outdated $outdated
}

# Fail when the configuration has any validation error-level issue. Advisory
# warning-level issues are printed so restore/update surface them before the
# final verification would fail opaquely.
def check-config [
  root: path # Private state root.
  config: record # Loaded configuration.
] {
  let issues = (validate-config $root $config)
  let errors = ($issues | where level == error)
  if ($errors | is-not-empty) {
    $errors | table | print --stderr
    fail "Configuration validation failed"
  }
  let warnings = ($issues | where level == warning)
  if ($warnings | is-not-empty) {
    warning "Configuration warnings; resolve them for a reproducible restore:"
    $warnings | table | print
  }
}

# Fail when a bootstrap-contract executable is missing for this recovery mode.
def check-bootstrap [
  --skip-software # Skip checks for mise (software-only tool).
] {
  let failures = (bootstrap-verify --skip-software=$skip_software | where {|item| not $item.ok })
  if ($failures | is-not-empty) {
    fail $"Bootstrap prerequisites are missing: (($failures | get check) | str join ', ')"
  }
}

# Run one restore stage against the checkpoint: skip it when already complete
# (--resume), record failures, and mark it complete on success. The action's
# return value (the number of package-manager failures it tolerated) is
# returned alongside the updated checkpoint so the workflow can fail with a
# summary after every stage has run.
def execute-stage [
  config: record # Loaded configuration.
  checkpoint: record # Current checkpoint.
  stage: string # Stage name.
  action: closure # Stage work to run.
  --dry-run # Do not persist checkpoint changes.
]: nothing -> record {
  if (stage-done $checkpoint $stage) {
    info $"resume: skipping completed stage '($stage)'"
    return {checkpoint: $checkpoint result: 0}
  }
  info $"stage: ($stage)"
  let outcome = (try {
    {ok: true message: "" result: (do $action)}
  } catch {|error|
    {ok: false message: (if $error.msg? == null { $error | to nuon } else { $error.msg }) result: 0}
  })
  if not $outcome.ok {
    fail-stage $config $checkpoint $stage $outcome.message --dry-run=$dry_run | ignore
    fail $"Restore stopped in stage '($stage)': ($outcome.message)"
  }
  let checkpoint = (complete-stage $config $checkpoint $stage --dry-run=$dry_run)
  {checkpoint: $checkpoint result: ($outcome.result? | default 0 | into int)}
}

# Restore the machine: native packages, mise tools, configuration, snapshots,
# and verification, in dependency order with checkpoint resume support.
export def workflow-restore [
  engine_root: path # Engine directory (checkpoint fingerprint scope).
  root: path # Private state root.
  config: record # Loaded configuration.
  --yes # Apply the recovery plan without asking for confirmation.
  --resume # Continue a matching interrupted restore.
  --dry-run # Show recovery actions without changing the machine.
  --skip-software # Skip native packages and mise-managed tools.
] {
  check-bootstrap --skip-software=$skip_software
  sync-engine-files $engine_root $root --dry-run=$dry_run
  check-config $root $config
  let plan = (workflow-plan $root $config --skip-software=$skip_software)
  $plan | table | print
  if not $dry_run and not (confirm "Apply this recovery plan?" --yes=$yes) { info "Restore cancelled"; return }

  mut checkpoint = (load-checkpoint $root $config (config-fingerprint $root $config --engine-root=$engine_root) --resume=$resume)
  mut failures = 0
  let os = (detect-os)
  if $skip_software {
    info "skipping system packages and portable tools"
  } else {
    let system = (execute-stage $config $checkpoint system-packages {
      mut stage_failures = 0
      if $os == "windows" { $stage_failures += (winget-restore $root $config --dry-run=$dry_run) }
      if $os == "macos" { $stage_failures += (homebrew-restore $root $config --dry-run=$dry_run) }
      if $os not-in [windows macos] { warning $"No native package integration for ($os)" }
      $stage_failures
    } --dry-run=$dry_run)
    $checkpoint = $system.checkpoint
    $failures += $system.result
    let portable = (execute-stage $config $checkpoint portable-tools {
      mise-restore $root $config --dry-run=$dry_run
    } --dry-run=$dry_run)
    $checkpoint = $portable.checkpoint
    $failures += $portable.result
  }
  # The macOS Finder context-menu services are machine configuration, so they
  # are restored even for offline (configuration-only) recovery.
  $checkpoint = ((execute-stage $config $checkpoint macos-finder {
    finder-restore $engine_root $root $config --dry-run=$dry_run
  } --dry-run=$dry_run) | get checkpoint)
  $checkpoint = ((execute-stage $config $checkpoint configuration {
    chezmoi-restore $root $config --dry-run=$dry_run
    # Regenerate generated shell init code only after chezmoi applies the home
    # state, so apply cannot overwrite the loader blocks and snippets.
    homebrew-persist-env $config --dry-run=$dry_run
    if not $skip_software { mise-configure-shells $root $config --dry-run=$dry_run }
  } --dry-run=$dry_run) | get checkpoint)
  $checkpoint = ((execute-stage $config $checkpoint snapshots {
    kopia-restore $config --dry-run=$dry_run
  } --dry-run=$dry_run) | get checkpoint)
  $checkpoint = ((execute-stage $config $checkpoint verification {
    if $dry_run {
      info $"would run verification checks: (workflow-verification-tools --skip-software=$skip_software | str join ', ')"
      0
    } else {
      workflow-verify $root $config --skip-software=$skip_software
      0
    }
  } --dry-run=$dry_run) | get checkpoint)
  if $failures > 0 {
    fail $"Package manager installs reported ($failures) failures; see the warnings above"
  }
  info "Restore completed"
}

# Capture managed dotfiles, software observations, and configured snapshots,
# optionally committing and pushing the private state repository.
export def workflow-backup [
  root: path # Private state root.
  config: record # Loaded configuration.
  --refresh-manifests # Replace desired native manifests with the full export.
  --commit # Commit captured changes to the private state repository.
  --push # Push the new backup commit; requires --commit.
  --dry-run # Show capture, snapshot, and Git actions without writing anything.
] {
  check-config $root $config
  if $push and not $commit { fail "--push requires --commit" }
  if $commit and not (git-status $root).available {
    fail "Cannot commit backup: Git is unavailable"
  }
  chezmoi-backup $root $config --dry-run=$dry_run
  winget-backup $root $config --refresh-manifests=$refresh_manifests --dry-run=$dry_run
  homebrew-backup $root $config --refresh-manifests=$refresh_manifests --dry-run=$dry_run
  finder-backup $root $config --dry-run=$dry_run
  tooling-backup $root $config --dry-run=$dry_run
  kopia-backup $config --dry-run=$dry_run
  if $commit {
    let secrets = (scan-commit-secrets $root)
    if ($secrets | is-not-empty) {
      $secrets | table --expand | print
      fail "Backup refused: changed files look like credentials; remove them, add them to chezmoi encryption, or exclude them from the private state before committing"
    }
    let changes = (commit-change-summary $root)
    if ($changes | is-not-empty) { $changes | table --expand | print }
    git-commit $root $config $"Backup (date now | format date '%Y-%m-%d')" --push=$push --dry-run=$dry_run
  }
  info "Backup capture completed; review the source diff"
}

# Pull the private state, update managed software, reapply dotfiles, and
# verify the result. The configuration is reloaded after the pull so updates
# honor the freshly pulled desired state.
export def workflow-update [
  engine_root: path # Engine directory (template source for engine-owned artifacts).
  root: path # Private state root.
  config: record # Loaded configuration (pre-pull).
  profiles: list<string> # Profile names to reload after the pull.
  --yes # Update without asking for confirmation.
  --dry-run # Show pull and update actions without changing anything.
] {
  check-bootstrap
  sync-engine-files $engine_root $root --dry-run=$dry_run
  check-config $root $config
  if not $dry_run and not (confirm "Pull configuration and update managed software?" --yes=$yes) { info "Update cancelled"; return }
  git-pull $root $config --dry-run=$dry_run
  let effective = if $dry_run { $config } else { load-config $root $profiles }
  check-config $root $effective
  mut failures = 0
  $failures += (winget-update $root $effective --dry-run=$dry_run)
  $failures += (homebrew-update $root $effective --dry-run=$dry_run)
  $failures += (mise-update $root $effective --dry-run=$dry_run)
  finder-restore $engine_root $root $effective --dry-run=$dry_run
  chezmoi-restore $root $effective --dry-run=$dry_run
  homebrew-persist-env $effective --dry-run=$dry_run
  mise-configure-shells $root $effective --dry-run=$dry_run
  if $dry_run { info "would run verification checks" } else { workflow-verify $root $effective }
  if $failures > 0 {
    fail $"Package manager updates reported ($failures) failures; see the warnings above"
  }
  info "Managed update completed"
}

# Compare desired software with installed software, report-only. Reconcile
# never changes desired state; it only writes fresh observations.
export def workflow-reconcile [
  root: path # Private state root.
  config: record # Loaded configuration.
  --dry-run # Avoid refreshing observations while producing the report.
] {
  check-config $root $config
  let native = if (detect-os) == "windows" {
    winget-reconcile $root $config --dry-run=$dry_run
  } else if (detect-os) == "macos" {
    homebrew-reconcile $root $config --dry-run=$dry_run
  } else {
    {tool: native applicable: false desired_only: [] observed_only: []}
  }
  $native | table --expand | print
  let portable = (mise-reconcile $root $config --dry-run=$dry_run)
  if ($portable | is-not-empty) { $portable | table --expand | print }
  let finder = (finder-reconcile $root $config --dry-run=$dry_run)
  if ($finder.applicable) { $finder | table --expand | print }
  let native_tools = (tooling-observe $root $config --dry-run=$dry_run)
  if ($native_tools | is-not-empty) { $native_tools | table --expand | print }
  info "Reconcile is report-only; desired state was not changed"
}

# Verify every enabled tool integration and fail when any check fails.
export def workflow-verify [
  root: path # Private state root.
  config: record # Loaded configuration.
  --skip-software # Verify dotfiles and snapshots without native packages or mise.
] {
  mut results = []
  for tool in (workflow-verification-tools --skip-software=$skip_software) {
    let checked = match $tool {
      bootstrap => (bootstrap-verify --skip-software=$skip_software)
      winget => (winget-verify $root $config)
      homebrew => (homebrew-verify $root $config)
      finder => (finder-verify $root $config)
      mise => (mise-verify $root $config)
      chezmoi => (chezmoi-verify $root $config)
      kopia => (kopia-verify $config)
    }
    $results = ($results | append $checked)
  }
  if ($results | is-empty) { warning "No verification checks are enabled"; return }
  $results | table --expand | print
  let failures = ($results | where {|item| not $item.ok })
  if ($failures | is-not-empty) { fail $"Verification failed: ($failures | length) checks" }
  info "Verification passed"
  warn-bootstrap-outdated (bootstrap-outdated --skip-software=$skip_software)
}

# Build an offline archive from committed engine and private-state snapshots.
export def workflow-bundle [
  engine_root: path # Engine directory.
  root: path # Private state root.
  config: record # Loaded configuration.
  output: path # Destination archive path.
  --dry-run # Show bundle contents without creating the archive.
] {
  check-config $root $config
  git-bundle $engine_root $root $output $config --dry-run=$dry_run
}
