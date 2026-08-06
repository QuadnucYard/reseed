#!/usr/bin/env nu

use lib/config.nu [load-config parse-profiles]
use lib/core.nu [expand-home]
use lib/workflow.nu [workflow-backup workflow-bundle workflow-init workflow-plan workflow-reconcile workflow-restore workflow-status workflow-update workflow-verify]

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

# Back up, restore, update, and verify a machine from a private Reseed state repository.
def main [] {
  help main
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
] {
  let state = (resolved-state-root $state_root)
  workflow-status $state (resolved-config $state $profiles)
}

# Recover software, dotfiles, and snapshots in dependency order, then verify them.
def "main restore" [
  --profiles (-p): string = "" # Comma-separated profiles; defaults to those configured in recovery.nuon.
  --state-root (-s): string = "" # Private state directory; overrides RESEED_STATE_ROOT and ~/.local/share/reseed.
  --yes (-y) # Apply the recovery plan without asking for confirmation.
  --resume # Continue a matching interrupted restore and skip its completed stages.
  --dry-run # Show recovery actions without changing the machine.
  --skip-software # Skip native packages and mise-managed tools; still restore configuration and snapshots.
] {
  let state = (resolved-state-root $state_root)
  workflow-restore (engine-root) $state (resolved-config $state $profiles) --yes=$yes --resume=$resume --dry-run=$dry_run --skip-software=$skip_software
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
  workflow-update $state (load-config $state $selected) $selected --yes=$yes --dry-run=$dry_run
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
