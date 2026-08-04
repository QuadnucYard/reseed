use core.nu [confirm detect-os fail info warning]
use config.nu [config-fingerprint load-config validate-config]
use state.nu [complete-stage fail-stage load-checkpoint stage-done]
use git.nu [git-bundle git-commit git-init git-pull git-status]
use ../integrations/chezmoi.nu [chezmoi-backup chezmoi-restore chezmoi-status chezmoi-verify]
use ../integrations/homebrew.nu [homebrew-backup homebrew-reconcile homebrew-restore homebrew-status homebrew-update homebrew-verify]
use ../integrations/kopia.nu [kopia-backup kopia-restore kopia-status kopia-verify]
use ../integrations/mise.nu [mise-reconcile mise-restore mise-status mise-update mise-verify]
use ../integrations/tooling.nu [tooling-backup tooling-observe]
use ../integrations/winget.nu [winget-backup winget-reconcile winget-restore winget-status winget-update winget-verify]

export def workflow-verification-tools [--skip-software]: nothing -> list<string> {
  let software = if $skip_software { [] } else { [winget homebrew mise] }
  $software | append [chezmoi kopia]
}

def state-template [engine_root: path]: nothing -> path {
  $engine_root | path join "templates" "state"
}

def state-sentinel [state_root: path]: nothing -> path {
  $state_root | path join ".reseed-state"
}

def ensure-state-root [engine_root: path state_root: path --dry-run] {
  let template = (state-template $engine_root)
  if not ($template | path exists) { fail $"State template is missing: ($template)" }
  if ($state_root | path exists) {
    let entries = (ls --all $state_root)
    if ($entries | is-not-empty) and not ((state-sentinel $state_root) | path exists) {
      fail $"Refusing nonempty directory without .reseed-state: ($state_root)"
    }
    if ((state-sentinel $state_root) | path exists) { return }
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

export def workflow-init [engine_root: path state_root: path profiles: list<string> --remote-url: string --dry-run] {
  ensure-state-root $engine_root $state_root --dry-run=$dry_run
  let config_root = if ((state-sentinel $state_root) | path exists) { $state_root } else { state-template $engine_root }
  let config = (load-config $config_root $profiles)
  check-config $config_root $config
  git-init $state_root $config --remote-url=$remote_url --dry-run=$dry_run
  info $"Private Reseed state: ($state_root)"
}

export def workflow-plan [root: path config: record --skip-software]: nothing -> list<record> {
  let os = (detect-os)
  let winget = (winget-status $root $config)
  let brew = (homebrew-status $root $config)
  let mise = (mise-status $root $config)
  let chezmoi = (chezmoi-status $root $config)
  let kopia = (kopia-status $config)
  [
    {order: 1 stage: system-packages enabled: ((not $skip_software) and (($os == "windows" and $winget.enabled) or ($os == "macos" and $brew.enabled))) owner: (if $os == "windows" { "winget" } else if $os == "macos" { "homebrew" } else { "unsupported" })}
    {order: 2 stage: portable-tools enabled: ((not $skip_software) and $mise.enabled) owner: mise}
    {order: 3 stage: configuration enabled: $chezmoi.enabled owner: chezmoi}
    {order: 4 stage: snapshots enabled: ($kopia.enabled and ($kopia.restores > 0)) owner: kopia}
    {order: 5 stage: verification enabled: true owner: reseed}
  ]
}

export def workflow-status [root: path config: record] {
  info $"platform: (detect-os)"
  info $"private state: ($root)"
  info $"profiles: ($config.active_profiles | str join ', ')"
  let git = (git-status $root)
  [
    (chezmoi-status $root $config)
    (winget-status $root $config)
    (homebrew-status $root $config)
    (mise-status $root $config)
    (kopia-status $config)
    ({tool: git enabled: true applicable: true available: $git.available repository: $git.repository clean: $git.clean})
  ] | table --expand | print

  let issues = (validate-config $root $config)
  if ($issues | is-empty) { info "desired-state files are present" } else { $issues | table | print }
}

def check-config [root: path config: record] {
  let issues = (validate-config $root $config)
  let errors = ($issues | where level == error)
  if ($errors | is-not-empty) {
    $errors | table | print --stderr
    fail "Configuration validation failed"
  }
}

def execute-stage [
  config: record
  checkpoint: record
  stage: string
  action: closure
  --dry-run
]: nothing -> record {
  if (stage-done $checkpoint $stage) {
    info $"resume: skipping completed stage '($stage)'"
    return $checkpoint
  }
  info $"stage: ($stage)"
  let outcome = (try {
    do $action
    {ok: true message: ""}
  } catch {|error|
    {ok: false message: (if $error.msg? == null { $error | to nuon } else { $error.msg })}
  })
  if not $outcome.ok {
    fail-stage $config $checkpoint $stage $outcome.message --dry-run=$dry_run | ignore
    fail $"Restore stopped in stage '($stage)': ($outcome.message)"
  }
  complete-stage $config $checkpoint $stage --dry-run=$dry_run
}

export def workflow-restore [engine_root: path root: path config: record --yes --resume --dry-run --skip-software] {
  check-config $root $config
  let plan = (workflow-plan $root $config --skip-software=$skip_software)
  $plan | table | print
  if not (confirm "Apply this recovery plan?" --yes=$yes) { info "Restore cancelled"; return }

  mut checkpoint = (load-checkpoint $root $config (config-fingerprint $root $config --engine-root=$engine_root) --resume=$resume)
  let os = (detect-os)
  if $skip_software {
    info "skipping system packages and portable tools"
  } else {
    $checkpoint = (execute-stage $config $checkpoint system-packages {
      if $os == "windows" { winget-restore $root $config --dry-run=$dry_run }
      if $os == "macos" { homebrew-restore $root $config --dry-run=$dry_run }
      if $os not-in [windows macos] { warning $"No native package integration for ($os)" }
    } --dry-run=$dry_run)
    $checkpoint = (execute-stage $config $checkpoint portable-tools {
      mise-restore $root $config --dry-run=$dry_run
    } --dry-run=$dry_run)
  }
  $checkpoint = (execute-stage $config $checkpoint configuration {
    chezmoi-restore $root $config --dry-run=$dry_run
  } --dry-run=$dry_run)
  $checkpoint = (execute-stage $config $checkpoint snapshots {
    kopia-restore $config --dry-run=$dry_run
  } --dry-run=$dry_run)
  $checkpoint = (execute-stage $config $checkpoint verification {
    if $dry_run {
      info $"would run verification checks: (workflow-verification-tools --skip-software=$skip_software | str join ', ')"
    } else {
      workflow-verify $root $config --skip-software=$skip_software
    }
  } --dry-run=$dry_run)
  info "Restore completed"
}

export def workflow-backup [
  root: path
  config: record
  --refresh-manifests
  --commit
  --push
  --dry-run
] {
  check-config $root $config
  if $push and not $commit { fail "--push requires --commit" }
  if $commit and not (git-status $root).available {
    fail "Cannot commit backup: Git is unavailable"
  }
  chezmoi-backup $root $config --dry-run=$dry_run
  winget-backup $root $config --refresh-manifests=$refresh_manifests --dry-run=$dry_run
  homebrew-backup $root $config --refresh-manifests=$refresh_manifests --dry-run=$dry_run
  tooling-backup $config --dry-run=$dry_run
  kopia-backup $config --dry-run=$dry_run
  if $commit { git-commit $root $config $"Backup (date now | format date '%Y-%m-%d')" --push=$push --dry-run=$dry_run }
  info "Backup capture completed; review the source diff"
}

export def workflow-update [root: path config: record profiles: list<string> --yes --dry-run] {
  check-config $root $config
  if not (confirm "Pull configuration and update managed software?" --yes=$yes) { info "Update cancelled"; return }
  git-pull $root $config --dry-run=$dry_run
  let effective = if $dry_run { $config } else { load-config $root $profiles }
  check-config $root $effective
  winget-update $root $effective --dry-run=$dry_run
  homebrew-update $root $effective --dry-run=$dry_run
  mise-update $root $effective --dry-run=$dry_run
  chezmoi-restore $root $effective --dry-run=$dry_run
  if $dry_run { info "would run verification checks" } else { workflow-verify $root $effective }
  info "Managed update completed"
}

export def workflow-reconcile [root: path config: record --dry-run] {
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
  let native_tools = (tooling-observe $config --dry-run=$dry_run)
  if ($native_tools | is-not-empty) { $native_tools | table --expand | print }
  info "Reconcile is report-only; desired state was not changed"
}

export def workflow-verify [root: path config: record --skip-software] {
  mut results = []
  for tool in (workflow-verification-tools --skip-software=$skip_software) {
    let checked = match $tool {
      winget => (winget-verify $root $config)
      homebrew => (homebrew-verify $root $config)
      mise => (mise-verify $root $config)
      chezmoi => (chezmoi-verify $root $config)
      kopia => (kopia-verify $config)
    }
    $results = ($results | append $checked)
  }
  if ($results | is-empty) { warning "No verification checks are enabled"; return }
  $results | table --expand | print
  let failures = ($results | where {|item| not $item.ok })
  if ($failures | is-not-empty) { fail $"Verification failed: ($failures | length) check(s)" }
  info "Verification passed"
}

export def workflow-bundle [engine_root: path root: path config: record output: path --dry-run] {
  check-config $root $config
  git-bundle $engine_root $root $output $config --dry-run=$dry_run
}
