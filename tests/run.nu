use ../lib/config.nu [config-fingerprint deep-merge load-config parse-profiles validate-config]
use ../lib/core.nu [show-command]
use ../lib/state.nu [checkpoint-path]
use ../lib/workflow.nu [workflow-plan workflow-verification-tools]
use ../integrations/homebrew.nu [brewfile-items]
use ../integrations/cargo_binstall.nu [cargo-binstall-packages]
use ../integrations/tooling.nu [tooling-observe]
use ../integrations/winget.nu [winget-manifest-ids]

def assert-equal [actual: any expected: any label: string] {
  if $actual != $expected {
    error make {msg: $"($label): expected ($expected | to nuon), got ($actual | to nuon)"}
  }
}

def assert-true [actual: bool label: string] {
  if not $actual { error make {msg: $"($label): expected true"} }
}

def main [] {
  let engine_root = ($env.FILE_PWD | path dirname)
  let state_root = ($engine_root | path join "templates" "state")

  let merged = (deep-merge
    {software: {mise: {enabled: true configs: [base]}} labels: [base]}
    {software: {mise: {configs: [work]}} labels: [work]})
  assert-equal $merged.software.mise.enabled true "deep merge preserves nested values"
  assert-equal $merged.software.mise.configs [work] "deep merge replaces arrays"
  assert-equal $merged.labels [work] "top-level arrays replace"

  assert-equal (parse-profiles " personal, work ") [personal work] "profile parsing"
  assert-equal (show-command "a tool" ["plain" "two words"]) '"a tool" plain "two words"' "command rendering"
  let config = (load-config $state_root [personal])
  assert-equal $config.active_profiles [personal] "active profile recording"
  assert-true ((validate-config $state_root $config) | is-empty) "state template validates"

  let cargo_config = ($config | upsert software.mise.cargo_binstall {
    enabled: true
    manifests: [packages/cargo/binstall.nuon]
    update: true
  })
  assert-true ((validate-config $state_root $cargo_config) | is-empty) "cargo-binstall config validates"
  let cargo_fixture_config = ($config | upsert software.mise.cargo_binstall {
    enabled: true
    manifests: [tests/fixtures/cargo-binstall.nuon]
    update: true
  })
  assert-equal (cargo-binstall-packages $engine_root $cargo_fixture_config) [alpha beta] "cargo-binstall packages are unique and sorted"

  let winget_ids = (winget-manifest-ids ($state_root | path join "packages" "windows" "winget.json"))
  assert-equal ($winget_ids | length) 4 "WinGet package extraction"
  assert-true ("jdx.mise" in $winget_ids) "WinGet contains bootstrap mise package"
  assert-equal (winget-manifest-ids ($engine_root | path join "tests" "fixtures" "winget-empty.json")) [] "empty WinGet export"

  let brew_items = (brewfile-items ($state_root | path join "packages" "macos" "Brewfile"))
  assert-equal ($brew_items | length) 5 "Brewfile item extraction"
  assert-true ('brew "chezmoi"' in $brew_items) "Brewfile contains chezmoi"
  assert-true ('brew "fish"' in $brew_items) "Brewfile contains fish"
  assert-equal (brewfile-items ($engine_root | path join "tests" "fixtures" "Brewfile.comments")) [
    'brew "git"'
    'cask "visual-studio-code"'
    'tap "homebrew/cask"'
  ] "Brewfile comments and blank lines"

  let plan = (workflow-plan $state_root $config)
  assert-equal ($plan.stage) [system-packages portable-tools configuration snapshots verification] "restore dependency order"
  assert-equal ($plan.order) [1 2 3 4 5] "restore ordering is stable"
  let offline_plan = (workflow-plan $state_root $config --skip-software)
  assert-equal ($offline_plan.enabled | first 2) [false false] "configuration-only restore skips software"
  assert-equal (workflow-verification-tools) [winget homebrew mise chezmoi kopia] "full verification scope"
  assert-equal (workflow-verification-tools --skip-software) [chezmoi kopia] "offline verification scope"

  let dry_state = ($engine_root | path join "tests" $".reseed-tooling-test-(random uuid)")
  let tooling_config = ($config
    | upsert state_dir ($dry_state | into string)
    | upsert observations.tool_managers [cargo pnpm bun uv npm yarn])
  let observations = (tooling-observe $tooling_config --dry-run)
  assert-equal ($observations.manager) [cargo pnpm bun uv uv npm yarn] "tool observation order"
  assert-true ($observations | where available | all {|item| $item.ok and $item.detail == "would capture" }) "available tool observations support dry run"
  assert-equal ($observations.observation | each {|path| $path | path basename }) [
    cargo-install.txt
    pnpm-global.json
    bun-global-package.json
    uv-tools.txt
    uv-python.json
    npm-global.json
    yarn-global.jsonl
  ] "tool observation filenames"
  assert-true (not ($dry_state | path exists)) "tool observation dry run writes no state"

  let unknown = (tooling-observe ($tooling_config | upsert observations.tool_managers [future-manager]) --dry-run | first)
  assert-equal $unknown.ok false "unknown observation manager is reported"
  assert-true ($unknown.migration | str contains "add an integration") "unknown observation manager reserves an extension point"

  let invalid_mise = ($config | upsert software.mise.configs [tools.custom.toml])
  let invalid_issues = (validate-config $state_root $invalid_mise)
  assert-true ($invalid_issues | any {|issue| $issue.area == mise and ($issue.message | str contains "Unsupported config name") }) "mise config names are validated"
  let missing_task = ($config | upsert software.mise.task_files [scripts/missing.nu])
  assert-true ((validate-config $state_root $missing_task) | any {|issue| $issue.area == mise and ($issue.message | str contains "Missing mise task file") }) "mise task files are validated"

  let checkpoint = (checkpoint-path $config | path basename)
  assert-true ($checkpoint | str contains "personal") "checkpoint is profile-specific"
  let state_fingerprint = (config-fingerprint $state_root $config)
  let restore_fingerprint = (config-fingerprint $state_root $config --engine-root=$engine_root)
  assert-equal ($state_fingerprint | str length) 64 "desired-state fingerprint"
  assert-equal ($restore_fingerprint | str length) 64 "engine-aware restore fingerprint"
  assert-true ($state_fingerprint != $restore_fingerprint) "engine changes invalidate restore checkpoints"

  print "All Reseed tests passed"
}
