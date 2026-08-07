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

use core.nu [command-exists fail info]
use setup/plan.nu [resolve-setup-features]
use setup/shared.nu [
  ask-default-yes
  gh-auth-status
  gpg-secret-key-id
  ssh-agent-running
  ssh-key-status
]
use setup/git.nu [git-signing-configured identity-present]
use setup/jj.nu [jj-signing-configured setup-jj-prereq setup-gpg-jj]
use setup/common.nu [setup-gh-auth setup-identity]
use setup/ssh.nu [
  github-has-ssh-key
  hosts-in-ssh-config
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
export use setup/ssh.nu [admin-key-path admin-keys-command ssh-config-merge]
export use setup/gpg.nu [gpg-batch-file]
export use setup/jj.nu [jj-signing-behaviors]

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
  let plan = (setup-plan $purpose --jj=$features.jj --gpg=$features.gpg)
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

  mut results = []
  for entry in $plan {
    let step = $entry.step
    if (setup-step-done $step $config) {
      $results = ($results | append {step: $step ok: true detail: "already done"})
      info $"skip ($step): already done"
      continue
    }
    if not $yes and not (ask-default-yes $"Run setup step '($step)'?") {
      $results = ($results | append {step: $step ok: true detail: "skipped by user"})
      continue
    }
    $results = ($results | append (run-setup-step $step $config --yes=$yes --dry-run=$dry_run --needs-gpg-upload=$needs_gpg_upload))
  }

  $results | table --expand | print
  let failures = ($results | where {|result| not $result.ok })
  if ($failures | is-not-empty) { fail $"Setup finished with ($failures | length) failed steps" }
  info "Setup completed"
}

# Dispatch a step name to its implementation.
def run-setup-step [
  step: string # Step name.
  config: record # Loaded configuration.
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
def setup-step-done [step: string, config: record]: nothing -> bool {
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
    gpg-prereq => (command-exists gpg)
    gpg-key => (gpg-secret-key-id | is-not-empty)
    gpg-github => (github-has-gpg-key)
    gpg-git => (git-signing-configured)
    gpg-jj => (jj-signing-configured)
    gpg-verify => false
    _ => false
  }
}
