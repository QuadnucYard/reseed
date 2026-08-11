use ../lib/prelude.nu *

# Availability and source for the chezmoi integration.
export def chezmoi-status [
  root: path # Private state root (the chezmoi source).
  config: record # Loaded configuration.
]: nothing -> record {
  {
    tool: chezmoi
    enabled: (($config.chezmoi? | default {}).enabled? | default false)
    applicable: true
    available: (command-exists chezmoi)
    source: ($root | into string)
  }
}

# Apply the chezmoi source. A diff runs first (failures tolerated) so the
# pending changes are visible before apply modifies the home directory.
export def chezmoi-restore [
  root: path # Private state root (the chezmoi source).
  config: record # Loaded configuration.
  --dry-run # Show the apply without running it.
] {
  let settings = $config.chezmoi
  if not ($settings.enabled? | default false) { return }
  if not (command-exists chezmoi) and not $dry_run { error make {msg: "chezmoi is required for the configuration stage"} }
  let source = ($root | into string)
  run-command chezmoi ["--source" $source "diff" "--no-pager"] --allow-failure --dry-run=$dry_run | ignore
  run-command chezmoi (["--source" $source "apply"] | append ($settings.apply_args? | default [])) --dry-run=$dry_run | ignore
}

# Re-import changed home files back into the chezmoi source so they become
# part of the private state.
export def chezmoi-backup [
  root: path # Private state root (the chezmoi source).
  config: record # Loaded configuration.
  --dry-run # Show the re-add without running it.
] {
  if not ($config.chezmoi.enabled? | default false) { return }
  if not (command-exists chezmoi) { warning "chezmoi is unavailable; skipping configuration capture"; return }
  run-command chezmoi ["--source" ($root | into string) "re-add"] --dry-run=$dry_run | ignore
}

# Verification checks for chezmoi: executable presence and that the target
# state matches the source (an empty diff).
export def chezmoi-verify [
  root: path # Private state root (the chezmoi source).
  config: record # Loaded configuration.
]: nothing -> list<record> {
  if not ($config.chezmoi.enabled? | default false) { return [] }
  if not (command-exists chezmoi) {
    return [{check: "chezmoi executable" ok: false detail: "not found"}]
  }
  let result = (run-command chezmoi ["--source" ($root | into string) "diff" "--no-pager"] --allow-failure --capture)
  let difference = ($result.stdout | str trim)
  [
    {check: "chezmoi executable" ok: true detail: "available"}
    {
      check: "chezmoi target state"
      ok: (($result.exit_code == 0) and ($difference | is-empty))
      detail: (if ($result.exit_code == 0) and ($difference | is-empty) { "matches source" } else { ($result.stdout + $result.stderr | str trim) })
    }
  ]
}
