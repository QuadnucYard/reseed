use node_manager.nu [node-manager-entries node-manager-missing-packages node-manager-packages node-manager-reconcile node-manager-restore node-manager-update node-manager-verify node-package-record parse-bun-inventory]

# Specifier strings for every configured bun global. See node-manager-packages.
export def bun-packages [root: path config: record]: nothing -> list<string> {
  node-manager-packages $root $config bun
}

# Normalized entries for every configured bun global. See node-manager-entries.
export def bun-entries [root: path config: record]: nothing -> list<record> {
  node-manager-entries $root $config bun
}

# Normalize a bun specifier plus commands into a package record.
export def bun-package-record [spec: string commands: list<string> = []]: nothing -> record {
  node-package-record $spec $commands
}

# Desired bun globals that are missing or at the wrong version.
export def bun-missing-packages [desired: list<record> installed: list<record>]: nothing -> list<record> {
  node-manager-missing-packages $desired $installed
}

# Install every configured bun global.
export def bun-restore [root: path config: record --dry-run] {
  node-manager-restore $root $config bun --dry-run=$dry_run
}

# Upgrade every configured bun global.
export def bun-update [root: path config: record --dry-run] {
  node-manager-update $root $config bun --dry-run=$dry_run
}

# Compare desired bun globals with the installed inventory, report-only.
export def bun-reconcile [root: path config: record --dry-run]: nothing -> record {
  node-manager-reconcile $root $config bun --dry-run=$dry_run
}

# Verification checks for bun globals.
export def bun-verify [root: path config: record]: nothing -> list<record> {
  node-manager-verify $root $config bun
}
