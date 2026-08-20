#!/usr/bin/env nu

use lib/config.nu [load-config parse-profiles]
use lib/core.nu [expand-home fail scrub-url]
use lib/git.nu [git-sync]
use lib/repo.nu [repo-merge-abort repo-merge-continue]
use lib/setup.nu [setup-wizard setup-ssh-host-add]
use lib/workflow.nu [workflow-backup workflow-bundle workflow-init workflow-plan workflow-reconcile workflow-restore workflow-status workflow-summary workflow-sync workflow-update workflow-verify]
use integrations/finder.nu [finder-restore finder-status finder-verify]

# Absolute path of the directory containing this engine.
def engine-root []: nothing -> path {
  $env.FILE_PWD | path expand --no-symlink
}

# Resolve the private state root from the CLI flag, the environment, or the
# default, expanding any leading ~ to the home directory.
def resolved-state-root [
  state_root: string # Explicit state root; empty defers to environment and default.
]: nothing -> path {
  let configured = if not ($state_root | str trim | is-empty) {
    $state_root
  } else if not ($env.RESEED_STATE_ROOT? | default "" | str trim | is-empty) {
    $env.RESEED_STATE_ROOT
  } else {
    "~/.local/share/reseed"
  }
  expand-home $configured | path expand --no-symlink
}

# Load the base configuration merged with the comma-separated profile list.
def resolved-config [
  state_root: path # Private state root.
  profiles: string # Comma-separated profiles.
]: nothing -> record {
  load-config $state_root (parse-profiles $profiles)
}

# Show the current machine status and the next recommended commands. Running
# `reseed` with no subcommand prints a compact, instant summary from local and
# cached facts: whether the fundamental software is in place, whether the local
# state is initialized, configuration health, whether the machine is restored
# to the current desired state, and the prioritized suggestions. Use
# `reseed status` for the full online view with a remote probe.
def main [
  --profiles (-p): string = "" # Comma-separated profiles; defaults to those configured in recovery.nuon.
  --state-root (-s): string = "" # Private state directory; overrides RESEED_STATE_ROOT and ~/.local/share/reseed.
  --offline # Accepted for symmetry with `reseed status`; the summary is always local.
] {
  let state = (resolved-state-root $state_root)
  let config = (try { load-config $state (parse-profiles $profiles) } catch { {} })
  workflow-summary (engine-root) $state $config
}

# Refresh an already-initialized private state root from the provided Git
# repository. Bootstrap helper used before restore; it does not load the
# configuration, so it works even when config/recovery.nuon is missing locally.
def "main sync-state" [
  --state-root (-s): string = "" # Private state directory; overrides RESEED_STATE_ROOT and ~/.local/share/reseed.
  --repository: string # Private state repository URL to fast-forward from.
] {
  if ($repository | str trim | is-empty) {
    fail "sync-state requires --repository"
  }
  let state = (resolved-state-root $state_root)
  git-sync $state $repository | ignore
}

# Link the local private state to the remote repository and adopt its state,
# for a machine bootstrapped without a repository once network access is
# configured. Adopts template seeds and empty roots directly, and refuses to
# overwrite local commits or uncommitted changes unless --replace is given.
def "main adopt" [
  --profiles (-p): string = "" # Comma-separated profiles; defaults to those configured in recovery.nuon.
  --state-root (-s): string = "" # Private state directory; overrides RESEED_STATE_ROOT and ~/.local/share/reseed.
  --remote-url: string # Private state repository URL to adopt.
  --replace # Discard local commits and uncommitted changes in favor of the provided state.
] {
  if ($remote_url | str trim | is-empty) {
    fail "adopt requires --remote-url"
  }
  let state = (resolved-state-root $state_root)
  let result = (git-sync $state $remote_url --replace=$replace)
  if not $result.synced {
    let guidance = match $result.status {
      dirty => "the local state has uncommitted changes; commit or stash them, or rerun with --replace to discard them"
      diverged => "the local state has diverged from the provided repository; push local commits or rerun with --replace to adopt the remote state"
      no-repo => "the state root is not initialized; run 'reseed init --remote-url ...' to seed and adopt it"
      _ => $"the local state could not be adopted: ($result.status)"
    }
    fail $"Could not adopt the private state from (scrub-url $remote_url): ($guidance)"
  }
  workflow-init (engine-root) $state (parse-profiles $profiles) --remote-url=$remote_url
}

# Create or validate a private state repository and initialize it with Git.
def "main init" [
  --profiles (-p): string = "" # Comma-separated profiles; defaults to those configured in recovery.nuon.
  --state-root (-s): string = "" # Private state directory; overrides RESEED_STATE_ROOT and ~/.local/share/reseed.
  --remote-url: string # Private Git remote URL to configure as origin.
  --dry-run # Show what would be initialized without writing files.
] {
  let state = (resolved-state-root $state_root)
  workflow-init (engine-root) $state (parse-profiles $profiles) --remote-url=$remote_url --dry-run=$dry_run
}

# Show the ordered recovery stages and whether each stage is enabled.
def "main plan" [
  --profiles (-p): string = "" # Comma-separated profiles; defaults to those configured in recovery.nuon.
  --state-root (-s): string = "" # Private state directory; overrides RESEED_STATE_ROOT and ~/.local/share/reseed.
  --skip-software # Exclude native packages and mise-managed tools from the plan.
] {
  let state = (resolved-state-root $state_root)
  let config = (resolved-config $state $profiles)
  workflow-plan $state $config --skip-software=$skip_software | table | print
}

# Report integration availability, repository state, and desired-state file health.
def "main status" [
  --profiles (-p): string = "" # Comma-separated profiles; defaults to those configured in recovery.nuon.
  --state-root (-s): string = "" # Private state directory; overrides RESEED_STATE_ROOT and ~/.local/share/reseed.
  --offline # Use local and cached repository facts instead of probing the remote.
] {
  let state = (resolved-state-root $state_root)
  let config = (try { load-config $state (parse-profiles $profiles) } catch { {} })
  workflow-status (engine-root) $state $config --offline=$offline
}

# Recover software, dotfiles, and snapshots in dependency order, then verify them.
def "main restore" [
  --profiles (-p): string = "" # Comma-separated profiles; defaults to those configured in recovery.nuon.
  --state-root (-s): string = "" # Private state directory; overrides RESEED_STATE_ROOT and ~/.local/share/reseed.
  --state-source: path = "" # Immutable downloaded private-state source to import into --state-root first.
  --yes (-y) # Apply the recovery plan without asking for confirmation.
  --resume # Continue a matching interrupted restore and skip its completed stages.
  --dry-run # Show recovery actions without changing the machine.
  --skip-software # Skip native packages and mise-managed tools; still restore configuration and snapshots.
] {
  let state = (resolved-state-root $state_root)
  workflow-restore (engine-root) $state (parse-profiles $profiles) --yes=$yes --resume=$resume --dry-run=$dry_run --skip-software=$skip_software --state-source=$state_source
}

# Capture managed dotfiles, software observations, and configured snapshots.
def "main backup" [
  --profiles (-p): string = "" # Comma-separated profiles; defaults to those configured in recovery.nuon.
  --state-root (-s): string = "" # Private state directory; overrides RESEED_STATE_ROOT and ~/.local/share/reseed.
  --refresh-manifests # Replace desired native-package manifests with all currently installed packages.
  --commit # Commit captured changes to the private state repository.
  --push # Push the new backup commit; requires --commit.
  --dry-run # Show capture, snapshot, and Git actions without writing anything.
] {
  let state = (resolved-state-root $state_root)
  workflow-backup $state (resolved-config $state $profiles) --refresh-manifests=$refresh_manifests --commit=$commit --push=$push --dry-run=$dry_run
}

# Pull private state, update managed software, reapply dotfiles, and verify the result.
def "main update" [
  --profiles (-p): string = "" # Comma-separated profiles; defaults to those configured in recovery.nuon.
  --state-root (-s): string = "" # Private state directory; overrides RESEED_STATE_ROOT and ~/.local/share/reseed.
  --yes (-y) # Update without asking for confirmation.
  --dry-run # Show pull and update actions without changing the repository or machine.
] {
  let state = (resolved-state-root $state_root)
  let selected = (parse-profiles $profiles)
  workflow-update (engine-root) $state (load-config $state $selected) $selected --yes=$yes --dry-run=$dry_run
}

# Synchronize the private state repository: attach a remote, fetch, fast-forward,
# or merge while preserving local history. --commit reviews and commits dirty
# state, --push publishes commits, and --continue/--abort finish or discard an
# interrupted merge.
def "main sync" [
  --profiles (-p): string = "" # Comma-separated profiles; defaults to those configured in recovery.nuon.
  --state-root (-s): string = "" # Private state directory; overrides RESEED_STATE_ROOT and ~/.local/share/reseed.
  --remote-url: string = "" # Private state repository URL to attach (existing origin wins).
  --commit # Review and commit dirty working-tree state.
  --push # Publish local (or newly created) commits to the remote.
  --yes (-y) # Skip confirmation prompts.
  --continue # Finish an interrupted merge after resolving its conflicts.
  --abort # Discard an interrupted merge and restore the pre-merge state.
  --dry-run # Show the sync actions without changing the repository.
] {
  let state = (resolved-state-root $state_root)
  if $continue and $abort { fail "--continue and --abort are mutually exclusive" }
  let selected = (parse-profiles $profiles)
  let config = (try { load-config $state $selected } catch { {} })
  if $continue {
    let result = (repo-merge-continue $state $config --push=$push --yes=$yes --dry-run=$dry_run)
    if not $result.synced { fail ($result.detail? | default "could not continue the merge") }
    info $result.detail
    return
  }
  if $abort {
    let result = (repo-merge-abort $state $config --dry-run=$dry_run)
    if not $result.synced { fail ($result.detail? | default "could not abort the merge") }
    info $result.detail
    return
  }
  let result = (workflow-sync (engine-root) $state $selected --remote-url=$remote_url --commit=$commit --push=$push --yes=$yes --dry-run=$dry_run)
  if not $result.synced and not $dry_run { fail ($result.detail? | default $"sync did not complete: ($result.status)") }
}

# Compare desired software with installed software without changing either.
def "main reconcile" [
  --profiles (-p): string = "" # Comma-separated profiles; defaults to those configured in recovery.nuon.
  --state-root (-s): string = "" # Private state directory; overrides RESEED_STATE_ROOT and ~/.local/share/reseed.
  --dry-run # Avoid refreshing observations while producing the comparison report.
] {
  let state = (resolved-state-root $state_root)
  workflow-reconcile $state (resolved-config $state $profiles) --dry-run=$dry_run
}

# Verify managed software, dotfiles, and configured snapshot repositories.
def "main verify" [
  --profiles (-p): string = "" # Comma-separated profiles; defaults to those configured in recovery.nuon.
  --state-root (-s): string = "" # Private state directory; overrides RESEED_STATE_ROOT and ~/.local/share/reseed.
  --skip-software # Verify dotfiles and snapshots without checking native packages or mise tools.
] {
  let state = (resolved-state-root $state_root)
  workflow-verify $state (resolved-config $state $profiles) --skip-software=$skip_software
}

# Build an offline archive from committed engine and private-state snapshots.
def "main bundle" [
  --profiles (-p): string = "" # Comma-separated profiles; defaults to those configured in recovery.nuon.
  --state-root (-s): string = "" # Private state directory; overrides RESEED_STATE_ROOT and ~/.local/share/reseed.
  --output (-o): path = reseed-source.tar.gz # Destination archive path.
  --dry-run # Show bundle contents and destination without creating the archive.
] {
  let state = (resolved-state-root $state_root)
  workflow-bundle (engine-root) $state (resolved-config $state $profiles) $output --dry-run=$dry_run
}

# Run the guided setup wizard over identity, SSH keys, GitHub uploads, and GPG signing.
def "main setup" [
  --profiles (-p): string = "" # Comma-separated profiles; defaults to those configured in recovery.nuon.
  --state-root (-s): string = "" # Private state directory; overrides RESEED_STATE_ROOT and ~/.local/share/reseed.
  --yes (-y) # Apply all defaults without per-step prompts.
  --dry-run # Show setup actions without changing the machine.
  --no-gpg # Skip the GPG signing area.
  --no-jj # Skip the jj area.
] {
  let state = (resolved-state-root $state_root)
  setup-wizard $state (resolved-config $state $profiles) all --yes=$yes --dry-run=$dry_run --no-gpg=$no_gpg --no-jj=$no_jj
}

# Set up only the Git and jj user identity.
def "main setup identity" [
  --profiles (-p): string = "" # Comma-separated profiles; defaults to those configured in recovery.nuon.
  --state-root (-s): string = "" # Private state directory; overrides RESEED_STATE_ROOT and ~/.local/share/reseed.
  --yes (-y) # Apply all defaults without per-step prompts.
  --dry-run # Show setup actions without changing the machine.
  --no-jj # Skip the jj area.
] {
  let state = (resolved-state-root $state_root)
  setup-wizard $state (resolved-config $state $profiles) identity --yes=$yes --dry-run=$dry_run --no-jj=$no_jj
}

# Set up the SSH agent and generate the default ed25519 key.
def "main setup ssh-local" [
  --profiles (-p): string = "" # Comma-separated profiles; defaults to those configured in recovery.nuon.
  --state-root (-s): string = "" # Private state directory; overrides RESEED_STATE_ROOT and ~/.local/share/reseed.
  --yes (-y) # Apply all defaults without per-step prompts.
  --dry-run # Show setup actions without changing the machine.
  --no-jj # Skip the jj area.
] {
  let state = (resolved-state-root $state_root)
  setup-wizard $state (resolved-config $state $profiles) ssh-local --yes=$yes --dry-run=$dry_run --no-jj=$no_jj
}

# Install the public key on every configured host.
def "main setup ssh-remote" [
  --profiles (-p): string = "" # Comma-separated profiles; defaults to those configured in recovery.nuon.
  --state-root (-s): string = "" # Private state directory; overrides RESEED_STATE_ROOT and ~/.local/share/reseed.
  --yes (-y) # Apply all defaults without per-step prompts.
  --dry-run # Show setup actions without changing the machine.
  --no-jj # Skip the jj area.
] {
  let state = (resolved-state-root $state_root)
  setup-wizard $state (resolved-config $state $profiles) ssh-remote --yes=$yes --dry-run=$dry_run --no-jj=$no_jj
}

# Add one remote SSH host to the base recovery configuration.
def "main setup ssh-host add" [
  --profiles (-p): string = "" # Comma-separated profile names.
  --state-root (-s): string = "" # Private state directory.
  --user: string = "" # SSH login user; prompts when omitted.
  --host: string = "" # Network hostname or address; prompts when omitted.
  --name: string # SSH Host name/alias; defaults to --host.
  --port: int # SSH port; prompts when omitted (default 22).
  --admin # Also install the key in the host admin allow list.
  --no-admin # Do not install the key in the host admin allow list.
  --os: string # Host OS; prompts when omitted (default unix).
  --yes (-y) # Accept the final add confirmation.
  --dry-run # Show the normalized host without writing.
] {
  let state = (resolved-state-root $state_root)
  let config = (resolved-config $state $profiles)
  setup-ssh-host-add $state $config --user=$user --host=$host --name=$name --port=$port --admin=$admin --no-admin=$no_admin --os=$os --yes=$yes --dry-run=$dry_run | ignore
}

# Set up local SSH keys, remote hosts, and connectivity tests.
def "main setup ssh" [
  --profiles (-p): string = "" # Comma-separated profiles; defaults to those configured in recovery.nuon.
  --state-root (-s): string = "" # Private state directory; overrides RESEED_STATE_ROOT and ~/.local/share/reseed.
  --yes (-y) # Apply all defaults without per-step prompts.
  --dry-run # Show setup actions without changing the machine.
  --no-jj # Skip the jj area.
] {
  let state = (resolved-state-root $state_root)
  setup-wizard $state (resolved-config $state $profiles) ssh --yes=$yes --dry-run=$dry_run --no-jj=$no_jj
}

# Authenticate the GitHub CLI and upload the SSH key.
def "main setup gh" [
  --profiles (-p): string = "" # Comma-separated profiles; defaults to those configured in recovery.nuon.
  --state-root (-s): string = "" # Private state directory; overrides RESEED_STATE_ROOT and ~/.local/share/reseed.
  --yes (-y) # Apply all defaults without per-step prompts.
  --dry-run # Show setup actions without changing the machine.
  --no-jj # Skip the jj area.
] {
  let state = (resolved-state-root $state_root)
  setup-wizard $state (resolved-config $state $profiles) gh --yes=$yes --dry-run=$dry_run --no-jj=$no_jj
}

# Set up GPG signing for Git and jj commits.
def "main setup gpg" [
  --profiles (-p): string = "" # Comma-separated profiles; defaults to those configured in recovery.nuon.
  --state-root (-s): string = "" # Private state directory; overrides RESEED_STATE_ROOT and ~/.local/share/reseed.
  --yes (-y) # Apply all defaults without per-step prompts.
  --dry-run # Show setup actions without changing the machine.
  --no-jj # Skip the jj area.
] {
  let state = (resolved-state-root $state_root)
  setup-wizard $state (resolved-config $state $profiles) gpg --yes=$yes --dry-run=$dry_run --no-jj=$no_jj
}

# Manage the macOS Finder context-menu services (status, restore, verify).
def "main finder" [] {
  help "main finder"
}

# Show whether the macOS Finder context-menu services are installed.
def "main finder status" [
  --profiles (-p): string = "" # Comma-separated profiles; defaults to those configured in recovery.nuon.
  --state-root (-s): string = "" # Private state directory; overrides RESEED_STATE_ROOT and ~/.local/share/reseed.
] {
  let state = (resolved-state-root $state_root)
  finder-status $state (resolved-config $state $profiles) | table --expand | print
}

# Install or refresh the macOS Finder context-menu services.
def "main finder restore" [
  --profiles (-p): string = "" # Comma-separated profiles; defaults to those configured in recovery.nuon.
  --state-root (-s): string = "" # Private state directory; overrides RESEED_STATE_ROOT and ~/.local/share/reseed.
  --dry-run # Show the writes and the Finder restart without changing files.
] {
  let state = (resolved-state-root $state_root)
  finder-restore (engine-root) $state (resolved-config $state $profiles) --dry-run=$dry_run
}

# Verify the installed macOS Finder context-menu services.
def "main finder verify" [
  --profiles (-p): string = "" # Comma-separated profiles; defaults to those configured in recovery.nuon.
  --state-root (-s): string = "" # Private state directory; overrides RESEED_STATE_ROOT and ~/.local/share/reseed.
] {
  let state = (resolved-state-root $state_root)
  finder-verify $state (resolved-config $state $profiles) | table --expand | print
}
