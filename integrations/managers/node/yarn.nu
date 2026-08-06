use node_manager.nu [node-manager-entries node-manager-missing-packages node-manager-packages node-manager-reconcile node-manager-restore node-manager-update node-manager-verify node-package-record]

# Specifier strings for every configured yarn global. See node-manager-packages.
export def yarn-packages [root: path config: record]: nothing -> list<string> {
  node-manager-packages $root $config yarn
}

# Normalized entries for every configured yarn global. See node-manager-entries.
export def yarn-entries [root: path config: record]: nothing -> list<record> {
  node-manager-entries $root $config yarn
}

# Normalize a yarn specifier plus commands into a package record.
export def yarn-package-record [spec: string commands: list<string> = []]: nothing -> record {
  node-package-record $spec $commands
}

# Desired yarn globals that are missing or at the wrong version.
export def yarn-missing-packages [desired: list<record> installed: list<record>]: nothing -> list<record> {
  node-manager-missing-packages $desired $installed
}

# Install every configured yarn global (requires Yarn 1).
export def yarn-restore [root: path config: record --dry-run] {
  node-manager-restore $root $config yarn --dry-run=$dry_run
}

# Upgrade every configured yarn global (requires Yarn 1).
export def yarn-update [root: path config: record --dry-run] {
  node-manager-update $root $config yarn --dry-run=$dry_run
}

# Compare desired yarn globals with the installed inventory, report-only.
export def yarn-reconcile [root: path config: record --dry-run]: nothing -> record {
  node-manager-reconcile $root $config yarn --dry-run=$dry_run
}

# Verification checks for yarn globals.
export def yarn-verify [root: path config: record]: nothing -> list<record> {
  node-manager-verify $root $config yarn
}
