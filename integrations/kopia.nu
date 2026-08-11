use ../lib/prelude.nu *

# Availability and configured snapshot/restore counts for kopia.
export def kopia-status [
  config: record # Loaded configuration.
]: nothing -> record {
  {
    tool: kopia
    enabled: (($config.kopia? | default {}).enabled? | default false)
    applicable: true
    available: (command-exists kopia)
    snapshots: (($config.kopia? | default {}).snapshot_paths? | default [] | length)
    restores: (($config.kopia? | default {}).restore? | default [] | length)
  }
}

# Snapshot every configured source path that exists; missing paths are
# reported as warnings rather than failures.
export def kopia-backup [
  config: record # Loaded configuration.
  --dry-run # Show the snapshot commands without running them.
] {
  if not ($config.kopia.enabled? | default false) { return }
  if not (command-exists kopia) { warning "Kopia is enabled but unavailable; skipping snapshots"; return }
  for item in ($config.kopia.snapshot_paths? | default []) {
    let path = (expand-home $item)
    if ($path | path exists) {
      run-command kopia ["snapshot" "create" ($path | into string)] --dry-run=$dry_run | ignore
    } else {
      warning $"Kopia snapshot path does not exist: ($path)"
    }
  }
}

# Restore every configured snapshot entry (snapshot ID to expanded target).
export def kopia-restore [
  config: record # Loaded configuration.
  --dry-run # Show the restore commands without running them.
] {
  if not ($config.kopia.enabled? | default false) { return }
  let restores = ($config.kopia.restore? | default [])
  if ($restores | is-empty) { return }
  if not (command-exists kopia) and not $dry_run { error make {msg: "Kopia is required for configured snapshot restores"} }
  for item in $restores {
    if ($item.snapshot? | default "" | is-empty) or ($item.target? | default "" | is-empty) {
      error make {msg: "Each Kopia restore entry needs snapshot and target"}
    }
    let target = (expand-home $item.target)
    run-command kopia ["snapshot" "restore" $item.snapshot ($target | into string)] --dry-run=$dry_run | ignore
  }
}

# Verification checks for kopia: executable presence and that every
# configured snapshot source exists.
export def kopia-verify [
  config: record # Loaded configuration.
]: nothing -> list<record> {
  if not ($config.kopia.enabled? | default false) { return [] }
  mut results = [{check: "kopia executable" ok: (command-exists kopia) detail: "optional snapshot manager"}]
  for item in ($config.kopia.snapshot_paths? | default []) {
    let path = (expand-home $item)
    $results = ($results | append {check: $"kopia source: ($item)" ok: ($path | path exists) detail: ($path | into string)})
  }
  $results
}
