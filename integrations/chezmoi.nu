use ../lib/core.nu [command-exists run-command warning]

export def chezmoi-status [root: path config: record]: nothing -> record {
  {
    tool: chezmoi
    enabled: ($config.chezmoi.enabled? | default false)
    applicable: true
    available: (command-exists chezmoi)
    source: ($root | into string)
  }
}

export def chezmoi-restore [root: path config: record --dry-run] {
  let settings = $config.chezmoi
  if not ($settings.enabled? | default false) { return }
  if not (command-exists chezmoi) and not $dry_run { error make {msg: "chezmoi is required for the configuration stage"} }
  let source = ($root | into string)
  run-command chezmoi ["--source" $source "diff" "--no-pager"] --allow-failure --dry-run=$dry_run | ignore
  run-command chezmoi (["--source" $source "apply"] | append ($settings.apply_args? | default [])) --dry-run=$dry_run | ignore
}

export def chezmoi-backup [root: path config: record --dry-run] {
  if not ($config.chezmoi.enabled? | default false) { return }
  if not (command-exists chezmoi) { warning "chezmoi is unavailable; skipping configuration capture"; return }
  run-command chezmoi ["--source" ($root | into string) "re-add"] --dry-run=$dry_run | ignore
}

export def chezmoi-verify [root: path config: record]: nothing -> list<record> {
  if not ($config.chezmoi.enabled? | default false) { return [] }
  if not (command-exists chezmoi) {
    return [{check: "chezmoi executable" ok: false detail: "not found"}]
  }
  let result = (run-command chezmoi ["--source" ($root | into string) "diff" "--no-pager"] --allow-failure)
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
