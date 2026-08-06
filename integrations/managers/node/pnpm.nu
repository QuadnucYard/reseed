use node_manager.nu [node-manager-entries node-manager-missing-packages node-manager-packages node-manager-reconcile node-manager-restore node-manager-update node-manager-verify node-package-record parse-node-dependency-inventory]

# Specifier strings for every configured pnpm global. See node-manager-packages.
export def pnpm-packages [root: path config: record]: nothing -> list<string> {
  node-manager-packages $root $config pnpm
}

# Normalized entries for every configured pnpm global. See node-manager-entries.
export def pnpm-entries [root: path config: record]: nothing -> list<record> {
  node-manager-entries $root $config pnpm
}

# Normalize a pnpm specifier plus commands into a package record.
export def pnpm-package-record [spec: string commands: list<string> = []]: nothing -> record {
  node-package-record $spec $commands
}

# Parse a pnpm global inventory into {name, version} records.
export def parse-pnpm-inventory [parsed: any]: nothing -> list<record> {
  parse-node-dependency-inventory $parsed
}

# Desired pnpm globals that are missing or at the wrong version.
export def pnpm-missing-packages [desired: list<record> installed: list<record>]: nothing -> list<record> {
  node-manager-missing-packages $desired $installed
}

# Install every configured pnpm global.
export def pnpm-restore [root: path config: record --dry-run] {
  node-manager-restore $root $config pnpm --dry-run=$dry_run
}

# Upgrade every configured pnpm global.
export def pnpm-update [root: path config: record --dry-run] {
  node-manager-update $root $config pnpm --dry-run=$dry_run
}

# Compare desired pnpm globals with the installed inventory, report-only.
export def pnpm-reconcile [root: path config: record --dry-run]: nothing -> record {
  node-manager-reconcile $root $config pnpm --dry-run=$dry_run
}

# Verification checks for pnpm globals.
export def pnpm-verify [root: path config: record]: nothing -> list<record> {
  node-manager-verify $root $config pnpm
}
