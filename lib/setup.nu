# Guided workstation setup: user identity, SSH keys, GitHub uploads, and
# commit signing. This facade runs the wizard and dispatches steps; the
# implementation lives in setup/ modules (plan, shared, git, jj, common,
# ssh, gpg).
#
# - setup/plan.nu: step metadata, purpose selection, ordering, feature gating
# - setup/shared.nu: machine-state detection and parsing
# - setup/git.nu: Git identity and signing
# - setup/jj.nu: jj installation, identity, and signing
# - setup/common.nu: cross-area steps (identity, gh auth)
# - setup/ssh.nu: SSH steps
# - setup/gpg.nu: GPG key steps

use core.nu [command-exists fail info run-command warning]
use config.nu [load-config validate-setup]
use setup/plan.nu [resolve-setup-features]
use setup/shared.nu [
  ask-default-yes
  gh-auth-status
  gpg-secret-key-id
  ssh-agent-running
  ssh-key-status
]
use setup/git.nu [git-config-get git-signing-configured identity-present setup-gpg-git]
use setup/jj.nu [jj-signing-configured setup-jj-prereq setup-gpg-jj]
use setup/common.nu [setup-gh-auth setup-identity]
use setup/provider.nu [repo-transport-check setup-gh-credential-helper setup-gh-repo-probe]
use setup/ssh.nu [
  github-has-ssh-key
  hosts-in-ssh-config
  normalize-ssh-host
  setup-hosts
  ssh-host-duplicate
  ssh-hosts-empty
  ssh-hosts-source-update
  hosts-keys-installed
  setup-ssh-agent
  setup-ssh-config
  setup-ssh-github
  setup-ssh-hosts
  setup-ssh-key
  setup-ssh-test
]
use setup/gpg.nu [
  github-has-gpg-key
  setup-gpg-github
  setup-gpg-key
  setup-gpg-prereq
  setup-gpg-verify
]

# Re-export the public helpers consumed outside the setup module (the CLI
# entrypoints and tests import them from here).
export use setup/plan.nu [setup-plan]
export use setup/shared.nu [parse-gh-scopes parse-gpg-secret-ids]
export use setup/ssh.nu [admin-key-path admin-keys-command normalize-ssh-host setup-hosts ssh-config-merge ssh-host-duplicate ssh-hosts-empty ssh-hosts-source-update ssh-install-args ssh-install-failure ssh-verification-args user-keys-command windows-admin-keys-script windows-user-keys-script]
export use setup/gpg.nu [gpg-batch-file]
export use setup/jj.nu [jj-signing-behaviors]
export use setup/provider.nu [parse-repo-url provider-descriptor repo-transport-check setup-gh-credential-helper setup-gh-repo-probe]

# The private state repository URL used by the protocol-aware gh purpose:
# the configured origin URL when present, otherwise config.git.url.
def state-repo-url [state_root: path, config: record]: nothing -> string {
  let remote = (($config.git? | default {}).remote? | default origin)
  let existing = (try {
    run-command git ["-C" ($state_root | into string) "remote" "get-url" $remote] --allow-failure --quiet --capture | get stdout | str trim
  } catch { "" })
  if not ($existing | is-empty) { $existing } else { ($config.git? | default {}).url? | default "" }
}

# Run the guided setup for one purpose: print the plan, confirm each step
# that is not already satisfied, and summarize the results.
export def setup-wizard [
  state_root: path # Private state root (configuration source).
  config: record # Loaded configuration; setup.ssh hosts and comment.
  purpose: string = "all" # Setup purpose to run.
  --yes # Apply all defaults without prompting.
  --dry-run # Show what each step would do without changing the machine.
  --no-gpg # Disable the GPG signing area.
  --no-jj # Disable the jj area.
] {
  let features = (resolve-setup-features --yes=$yes --no-gpg=$no_gpg --no-jj=$no_jj)
  let repo_url = (state-repo-url $state_root $config)
  let plan = (setup-plan $purpose --jj=$features.jj --gpg=$features.gpg --repo-url=$repo_url)
  if ($plan | is-empty) { info "No setup steps selected; nothing to do"; return }
  let needs_gpg_upload = ($plan | any {|entry| $entry.step == gpg-github })
  info $"setup purpose: ($purpose)"
  if not $features.jj_present {
    info (if $features.jj { "jj will be installed" } else { "jj is disabled; its steps are skipped" })
  }
  if not $features.gpg_present {
    info (if $features.gpg { "GnuPG will be installed" } else { "GPG signing is disabled; its steps are skipped" })
  }
  $plan | table | print

  let no_hosts = (ssh-hosts-empty $config)
  let has_remote_steps = ($plan | any {|entry| $entry.step in [ssh-hosts ssh-config ssh-test] })
  if $no_hosts and $has_remote_steps {
    info "No SSH hosts configured; remote SSH steps will be skipped. Add one with: nu reseed.nu setup ssh-host add"
  }

  mut results = []
  for entry in $plan {
    let step = $entry.step
    if $no_hosts and $step in [ssh-hosts ssh-config ssh-test] {
      $results = ($results | append {step: $step ok: true detail: "no hosts configured; add one with 'nu reseed.nu setup ssh-host add'"})
      info $"skip ($step): no hosts configured"
      continue
    }
    if (setup-step-done $step $config $repo_url) {
      $results = ($results | append {step: $step ok: true detail: "already done"})
      info $"skip ($step): already done"
      continue
    }
    if not $yes and not (ask-default-yes $"Run setup step '($step)'?") {
      $results = ($results | append {step: $step ok: true detail: "skipped by user"})
      continue
    }
    $results = ($results | append (run-setup-step $step $config $repo_url --yes=$yes --dry-run=$dry_run --needs-gpg-upload=$needs_gpg_upload))
  }

  $results | table --expand | print
  let failures = ($results | where {|result| not $result.ok })
  if ($failures | is-not-empty) { fail $"Setup finished with ($failures | length) failed steps" }
  info "Setup completed"
}

# Add one host to the base recovery configuration after confirmation.
export def setup-ssh-host-add [
  state_root: path
  config: record
  --user: string = ""
  --host: string = ""
  --port: int
  --admin
  --no-admin
  --os: string
  --yes
  --dry-run
]: nothing -> record {
  let active_profiles = ($config.active_profiles? | default [])
  let overridden = ($active_profiles | where {|profile|
    let path = ($state_root | path join "config" "profiles" $"($profile).nuon")
    if not ($path | path exists) { false } else {
      let profile_config = (open $path)
      (($profile_config.setup? | default {}).ssh? | default {}).hosts? != null
    }
  })
  if ($overridden | is-not-empty) {
    fail $"Cannot add a base SSH host while profile(s) override setup.ssh.hosts: (($overridden | str join ', ')); remove the override or rerun without those profiles"
  }

  if $admin and $no_admin { fail "--admin and --no-admin are mutually exclusive" }
  let user = if ($user | str trim | is-empty) { input "SSH user: " | str trim } else { $user | str trim }
  let host = if ($host | str trim | is-empty) { input "SSH host: " | str trim } else { $host | str trim }
  let port_value = if $port != null {
    $port
  } else if $yes {
    22
  } else {
    let answer = (input --default "22" "SSH port [22]: " | str trim)
    try { $answer | into int } catch { fail "SSH port must be an integer" }
  }
  let admin_value = if $admin {
    true
  } else if $no_admin or $yes {
    false
  } else {
    let answer = (input --default "n" "Install for host administrators? [y/N]: " | str trim | str lowercase)
    if $answer in [y yes] { true } else if $answer in [n no ""] { false } else { fail "Admin choice must be yes or no" }
  }
  let os_value = if $os != null and not ($os | str trim | is-empty) {
    $os | str lowercase | str trim
  } else if $yes {
    "unix"
  } else {
    input --default "unix" "Host OS (windows, macos, unix) [unix]: " | str lowercase | str trim
  }
  if ($user | is-empty) { fail "SSH user must not be empty" }
  if ($host | is-empty) { fail "SSH host must not be empty" }
  if $port_value < 1 or $port_value > 65535 { fail "SSH port must be between 1 and 65535" }
  if $os_value not-in [windows macos unix] { fail "SSH OS must be windows, macos, or unix" }
  if ($user | str contains "\n") or ($host | str contains "\n") { fail "SSH user and host must be single-line values" }
  let candidate = (normalize-ssh-host $user $host $port_value $admin_value $os_value)
  if (ssh-host-duplicate $config $candidate) { fail $"SSH host already configured for ($candidate.host):($candidate.port)" }
  print "SSH host to add:"
  $candidate | table --expand | print
  if $dry_run {
    info "dry-run: configuration was not changed"
    return {added: false dry_run: true host: $candidate}
  }
  if not $yes and not (ask-default-yes "Add this SSH host?") {
    info "SSH host addition cancelled"
    return {added: false dry_run: false host: $candidate}
  }
  let path = ($state_root | path join "config" "recovery.nuon")
  if not ($path | path exists) { fail $"Base configuration not found: ($path)" }
  let source = (open --raw $path)
  let base = (open $path)
  let hosts = (setup-hosts $base | append $candidate)
  let updated_source = (ssh-hosts-source-update $source $base $hosts)
  let parsed = (try { $updated_source | from nuon } catch {|error| fail $"Updated SSH configuration is invalid: ($error.msg? | default ($error | to nuon))" })
  let issues = (validate-setup $parsed | where level == error)
  if ($issues | is-not-empty) { fail $"Updated SSH configuration failed validation: (($issues | get message | str join '; '))" }
  let temp = ($path | path dirname | path join $".recovery.nuon.(random uuid).tmp")
  try {
    $updated_source | save --force $temp
    mv --force $temp $path
  } catch {|error|
    if ($temp | path exists) { rm $temp }
    fail $"Could not update SSH configuration: ($error.msg? | default ($error | to nuon))"
  }
  info $"Added SSH host ($candidate.user)@($candidate.host):($candidate.port)"
  {added: true dry_run: false host: $candidate}
}

# Dispatch a step name to its implementation.
def run-setup-step [
  step: string # Step name.
  config: record # Loaded configuration.
  repo_url: string # Private state repository URL for protocol-aware steps.
  --yes # Apply defaults without prompting.
  --dry-run # Show the step without changing the machine.
  --needs-gpg-upload # Whether the plan uploads a GPG key.
]: nothing -> record {
  match $step {
    jj-prereq => (setup-jj-prereq --dry-run=$dry_run)
    identity => (setup-identity $config --yes=$yes --dry-run=$dry_run)
    gh-auth => (setup-gh-auth --yes=$yes --dry-run=$dry_run --needs-gpg-upload=$needs_gpg_upload)
    ssh-agent => (setup-ssh-agent --dry-run=$dry_run)
    ssh-key => (setup-ssh-key $config --dry-run=$dry_run)
    ssh-github => (setup-ssh-github --dry-run=$dry_run)
    ssh-hosts => (setup-ssh-hosts $config --dry-run=$dry_run)
    ssh-config => (setup-ssh-config $config --dry-run=$dry_run)
    ssh-test => (setup-ssh-test $config --dry-run=$dry_run)
    gh-credential-helper => (setup-gh-credential-helper --dry-run=$dry_run)
    gh-repo-probe => (setup-gh-repo-probe $repo_url --dry-run=$dry_run)
    gpg-prereq => (setup-gpg-prereq --dry-run=$dry_run)
    gpg-key => (setup-gpg-key --dry-run=$dry_run)
    gpg-github => (setup-gpg-github --dry-run=$dry_run)
    gpg-git => (setup-gpg-git --dry-run=$dry_run)
    gpg-jj => (setup-gpg-jj --yes=$yes --dry-run=$dry_run)
    gpg-verify => (setup-gpg-verify --dry-run=$dry_run)
    _ => {step: $step ok: false detail: "unknown setup step"}
  }
}

# Whether a step is already satisfied and can be skipped.
def setup-step-done [step: string, config: record, repo_url: string]: nothing -> bool {
  match $step {
    jj-prereq => (command-exists jj)
    identity => (identity-present)
    gh-auth => (gh-auth-status).authed
    ssh-agent => (ssh-agent-running)
    ssh-key => (ssh-key-status).key_present
    ssh-github => (github-has-ssh-key)
    ssh-hosts => (hosts-keys-installed $config)
    ssh-config => (hosts-in-ssh-config $config)
    ssh-test => (hosts-keys-installed $config)
    gh-credential-helper => (not ((git-config-get "credential.helper") | is-empty))
    gh-repo-probe => (repo-transport-check $repo_url).ok
    gpg-prereq => (command-exists gpg)
    gpg-key => (gpg-secret-key-id | is-not-empty)
    gpg-github => (github-has-gpg-key)
    gpg-git => (git-signing-configured)
    gpg-jj => (jj-signing-configured)
    gpg-verify => false
    _ => false
  }
}
