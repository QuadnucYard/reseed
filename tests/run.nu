use std assert
use ./helpers.nu *
use ../lib/core.nu [detect-os]
use ../lib/config.nu [config-fingerprint deep-merge load-config parse-profiles validate-config]
use ../lib/advice.nu [recommend]
use ../lib/import.nu [import-state-source state-source-probe]
use ../lib/git.nu [git-sync]
use ../lib/repo.nu [import-record-load merge-intent-clear merge-intent-load merge-intent-save repo-merge-abort repo-merge-continue repo-probe repo-push repo-refresh repo-sync]
use ../lib/prelude.nu *
use ../lib/workflow.nu [prepare-state sync-engine-files workflow-init workflow-plan workflow-status-facts workflow-verification-tools]
use ../lib/secrets.nu [commit-change-summary scan-commit-secrets secret-content-matches secret-name-matches]
use ../integrations/bootstrap.nu [bootstrap-brew-items bootstrap-latest bootstrap-outdated bootstrap-tools bootstrap-winget-ids parse-brew-outdated parse-winget-upgrade-table]
use ../integrations/homebrew.nu [brewfile-items brewfile-summary homebrew-env homebrew-mirror-label homebrew-persist-env homebrew-shell-snippets native-brewfile-items parse-outdated-names]
use ../integrations/managers/cargo_binstall.nu [cargo-binstall-args cargo-binstall-packages]
use ../integrations/mise.nu [mise-configure-shells mise-install-plan mise-reconcile mise-shell-task mise-shell-task-environment]
use ../integrations/managers/node/node_manager.nu [node-manager-entries node-manager-install-args node-manager-missing-packages node-manager-update-args node-package-record node-spec-parse node-yarn-major-version parse-bun-inventory parse-node-dependency-inventory parse-yarn-inventory]
use ../integrations/managers/node/pnpm.nu [parse-pnpm-inventory pnpm-missing-packages pnpm-package-record pnpm-packages]
use ../integrations/tooling.nu [tooling-observe]
use ../integrations/managers/uv.nu [parse-uv-inventory uv-entries uv-missing-packages uv-package-record uv-packages uv-spec-parse]
use ../integrations/winget.nu [native-winget-manifest-ids winget-manifest-ids]

def with-temp-dir [template: string body: closure] {
  let sandbox = (mktemp --directory --tmpdir $template)
  try {
    let result = (do $body $sandbox)
    rm --recursive --force $sandbox
    $result
  } catch {|err|
    rm --recursive --force $sandbox
    error make $err
  }
}

# Set a local Git identity on a disposable repository so commits work on CI
# runners that have no user.name/user.email configured globally, and disable
# commit signing locally so a host that enables GPG signing cannot break the
# behavior tests. Together with the isolated GIT_CONFIG_GLOBAL in main, test
# repositories never inherit the host's signing configuration.
def configure-git-identity [repo: path] {
  run-command git ["-C" ($repo | into string) "config" "user.email" "reseed@example.com"] --quiet | ignore
  run-command git ["-C" ($repo | into string) "config" "user.name" "Reseed Test"] --quiet | ignore
  run-command git ["-C" ($repo | into string) "config" "commit.gpgsign" "false"] --quiet | ignore
}

# A minimal git configuration used by sync tests.
def test-git-config []: nothing -> record {
  {git: {remote: origin branch: main}}
}

# Configuration loading: deep merge, profile parsing, command display and
# URL redaction, missing-command capture, and template validation.
def test-config-layer [
  state_root: path # Private state template root.
] {
  let merged = (deep-merge
    {software: {mise: {enabled: true configs: [base]}} labels: [base]}
    {software: {mise: {configs: [work]}} labels: [work]})
  assert eq $merged.software.mise.enabled true "deep merge preserves nested values"
  assert eq $merged.software.mise.configs [work] "deep merge replaces arrays"
  assert eq $merged.labels [work] "top-level arrays replace"

  assert eq (parse-profiles " personal, work ") [personal work] "profile parsing"
  assert eq (show-command "a tool" ["plain" "two words"]) '"a tool" plain "two words"' "command rendering"
  assert eq (scrub-url "https://user:token@example.com/repo") "https://***@example.com/repo" "URL credentials are redacted"
  assert eq (scrub-url "https://example.com/repo") "https://example.com/repo" "URLs without credentials are unchanged"
  assert eq (scrub-url "ssh://git@example.com/repo") "ssh://***@example.com/repo" "SSH URLs with userinfo are redacted"
  assert eq (show-command git ["clone" "https://user:token@example.com/repo"]) "git clone https://***@example.com/repo" "command display redacts credentials"
  # expand-home normalizes separators so tools that compare paths against PATH
  # (e.g. pnpm's global bin directory check) see one consistent platform form.
  let normalized_home = (($nu.home-dir | path join ".local" "share" "reseed" "bin") | path expand --no-symlink | into string)
  assert eq ((expand-home "~/.local/share/reseed/bin" | into string)) $normalized_home "expand-home normalizes platform separators"
  let missing_command = (run-command "reseed-no-such-command" [] --allow-failure --quiet)
  assert eq $missing_command.exit_code 127 "missing executables stream a normalized failure"
  let missing_captured = (run-command "reseed-no-such-command" [] --allow-failure --quiet --capture)
  assert eq $missing_captured.exit_code 127 "missing executables are captured under allow-failure"
  let failed_run = (run-command nu ["-c" "exit 5"] --allow-failure --quiet)
  assert eq $failed_run.exit_code 5 "streamed commands report their real exit code"
  assert eq ($failed_run.stdout + $failed_run.stderr) "" "streamed commands do not fill the result record"
  let success_run = (run-command nu ["--version"] --allow-failure --quiet)
  assert eq $success_run.exit_code 0 "successful streamed commands exit clean"
  let success_captured = (run-command nu ["-c" "print hi"] --allow-failure --quiet --capture)
  assert eq ($success_captured.stdout | str trim) "hi" "captured commands collect stdout"
  # A failing command without --allow-failure must raise a catchable error
  # (not exit the shell), so stages can record and resume around the failure.
  let failure_error = (try {
    run-command nu ["-c" "exit 5"] --quiet
    {caught: false message: ""}
  } catch {|error|
    {caught: true message: ($error.msg? | default "")}
  })
  assert $failure_error.caught "failing commands raise a catchable error"
  assert ($failure_error.message | str contains "exit code 5") "command failure message reports the exit code"
  let warned = (run-or-warn nu ["-c" "exit 7"] --quiet --label="probe")
  assert eq $warned.exit_code 7 "run-or-warn reports the failing exit code"
  let warned_dry = (run-or-warn nu ["-c" "exit 7"] --quiet --dry-run)
  assert eq $warned_dry.exit_code 0 "run-or-warn dry runs report success"
  let config = (load-config $state_root [personal])
  assert eq (mise-shell-task $config.software.mise) "reseed:shells" "explicit shell task selection"
  let shell_environment = (mise-shell-task-environment $state_root $config)
  assert eq $shell_environment.MISE_GLOBAL_CONFIG_FILE (($state_root | path join "mise.toml") | path expand --no-symlink | into string) "shell task pins mise global config"
  assert eq $shell_environment.RESEED_MISE_CONFIG_FILE $shell_environment.MISE_GLOBAL_CONFIG_FILE "shell task propagates selected config"
  let legacy_settings = ($config.software.mise | reject shell_task | upsert restore_tasks ["reseed:shells" "reseed:other"])
  assert eq (mise-shell-task $legacy_settings) "reseed:shells" "legacy shell task selection"
  assert eq $config.active_profiles [personal] "active profile recording"
  assert ((validate-config $state_root $config) | is-empty) "state template validates"
  let without_setup = ($config | reject --optional setup)
  assert ((validate-config $state_root $without_setup) | is-empty) "configs without a setup section validate"
}

# Desired-state reading: uv and Node manager manifest entries and their
# merging rules.
def test-manager-entries [
  engine_root: path # Engine root for fixture paths.
  state_root: path # Private state template root.
] {
  let config = (load-config $state_root [personal])
  assert eq (uv-packages $state_root $config) [ruff] "uv manifest packages"
  assert eq (pnpm-packages $state_root $config) ["@biomejs/biome"] "pnpm manifest packages"
  assert eq (uv-entries $state_root $config) [{spec: ruff name: ruff version: null commands: [ruff]}] "uv command declaration"
  assert eq (node-manager-entries $state_root $config pnpm) [{spec: "@biomejs/biome" name: "@biomejs/biome" version: null commands: [biome]}] "pnpm command declaration"
  assert eq (node-manager-entries $state_root $config yarn) [] "yarn sibling manifest"
  assert eq (node-manager-entries $state_root $config bun) [] "bun sibling manifest"
  let commands_config = ($config | upsert software.mise.pnpm.manifests [tests/fixtures/pnpm-commands-a.nuon tests/fixtures/pnpm-commands-b.nuon])
  assert eq (node-manager-entries $engine_root $commands_config pnpm) [{spec: "@biomejs/biome" name: "@biomejs/biome" version: null commands: [biome biome-fmt]}] "duplicate node manager specs merge commands"
  let all_node_managers = ($config
    | upsert software.mise.yarn {enabled: true manifests: [packages/node/yarn/global.nuon] update: true}
    | upsert software.mise.bun {enabled: true manifests: [packages/node/bun/global.nuon] update: true})
  assert eq (mise-reconcile $state_root $all_node_managers --dry-run | get tool) [mise uv pnpm yarn bun] "Node managers share the mise lifecycle"
  let mise_tools = (open ($state_root | path join "mise.toml")).tools
  for key in [node "aqua:pnpm/pnpm" "aqua:astral-sh/uv"] {
    assert ($key in ($mise_tools | columns)) $"mise owns ($key)"
  }
  assert eq $config.software.mise.manager_config "mise.toml" "mise manager config"
}

# The bootstrap contract: the tools the engine owns and the identifiers
# native manifests must exclude.
def test-bootstrap-contract [] {
  assert eq (bootstrap-tools | get command) [git chezmoi nu mise] "bootstrap contract"
  assert eq (bootstrap-winget-ids) ["Git.Git" "twpayne.chezmoi" "Nushell.Nushell" "jdx.mise"] "bootstrap WinGet ids"
  assert eq (bootstrap-tools | get name) (bootstrap-brew-items | each {|item| $item | str replace --regex '^brew "' "" | str replace '"' "" }) "brew items match tool names"
}

# Outdated-tool detection: both Homebrew output formats and the WinGet
# upgrade table parse into name -> latest records.
def test-bootstrap-updates [] {
  assert eq (bootstrap-latest | describe) "record" "unsupported platforms return an empty bootstrap update record"
  let brew_old = "git 2.47.1 < 2.48.0\nfish 3.7.1 < 3.7.2\nchezmoi 2.57.0 < 2.58.0"
  assert eq (parse-brew-outdated $brew_old) {git: "2.48.0" chezmoi: "2.58.0"} "brew outdated parses the old format"
  let brew_new = "git (installed: 2.47.1) != 2.48.0\nnushell (installed: 0.114.1) != 0.115.0"
  assert eq (parse-brew-outdated $brew_new) {git: "2.48.0" nushell: "0.115.0"} "brew outdated parses the new format"
  assert eq (parse-brew-outdated "") {} "brew output without rows is empty"
  let winget = "Name Id Version Available Source\n---- -- ------- --------- ------\nGit Git.Git 2.47.1 2.48.0 winget\nNushell Nushell.Nushell 0.114.1 0.115.0 winget"
  assert eq (parse-winget-upgrade-table $winget) {git: "2.48.0" nushell: "0.115.0"} "winget upgrade table maps ids to tool names"
  assert eq (parse-winget-upgrade-table "No available upgrade found.") {} "winget output without rows is empty"
}

# Cargo-binstall manifest reading and validation.
def test-cargo-binstall [
  engine_root: path # Engine root for fixture paths.
  state_root: path # Private state template root.
] {
  let config = (load-config $state_root [personal])
  let cargo_config = ($config | upsert software.mise.cargo_binstall {
    enabled: true
    manifests: [packages/cargo/binstall.nuon]
    update: true
  })
  let cargo_issues = (validate-config $state_root $cargo_config)
  assert (($cargo_issues | where level == error) | is-empty) "cargo-binstall config validates without errors"
  assert ($cargo_issues | any {|issue| $issue.level == warning and $issue.area == cargo_binstall and ($issue.message | str contains "aqua:cargo-bins/cargo-binstall") }) "enabling cargo-binstall without its mise tool warns with the [tools] entry to add"
  let cargo_fixture_config = ($config | upsert software.mise.cargo_binstall {
    enabled: true
    manifests: [tests/fixtures/cargo-binstall.nuon]
    update: true
  })
  assert eq (cargo-binstall-packages $engine_root $cargo_fixture_config) [alpha beta] "cargo-binstall packages are unique and sorted"
}

# WinGet manifest extraction and bootstrap-tool filtering.
def test-winget-manifests [
  engine_root: path # Engine root for fixture paths.
  state_root: path # Private state template root.
] {
  let bootstrap_ids = (bootstrap-winget-ids)
  let winget_ids = (winget-manifest-ids ($state_root | path join "packages" "windows" "winget.json"))
  assert eq ($winget_ids | length) 0 "empty example WinGet manifest extraction"
  assert (not ($winget_ids | any {|id| $id in $bootstrap_ids })) "WinGet excludes bootstrap tools"
  assert eq (winget-manifest-ids ($engine_root | path join "tests" "fixtures" "winget-empty.json")) [] "empty WinGet export"
  assert eq (native-winget-manifest-ids ($engine_root | path join "tests" "fixtures" "winget-bootstrap.json")) [example.tool] "WinGet filters bootstrap packages"
}

# Brewfile extraction and bootstrap-tool filtering.
def test-brewfile-manifests [
  engine_root: path # Engine root for fixture paths.
  state_root: path # Private state template root.
] {
  let bootstrap_items = (bootstrap-brew-items)
  let brew_items = (brewfile-items ($state_root | path join "packages" "macos" "Brewfile"))
  assert eq ($brew_items | length) 1 "curated Brewfile item extraction"
  assert ('brew "fish"' in $brew_items) "Brewfile contains fish"
  assert (not ($brew_items | any {|item| $item in $bootstrap_items })) "Brewfile excludes bootstrap tools"
  assert eq (brewfile-items ($engine_root | path join "tests" "fixtures" "Brewfile.comments")) [
    'brew "git"'
    'cask "visual-studio-code"'
    'tap "homebrew/cask"'
  ] "Brewfile comments and blank lines"
  assert eq (native-brewfile-items ($engine_root | path join "tests" "fixtures" "Brewfile.bootstrap")) ['brew "fish"'] "Brewfile filters bootstrap packages"
  assert eq (brewfile-summary ($state_root | path join "packages" "macos" "Brewfile")) "1 formula" "Brewfile summary counts formulas"
  assert eq (brewfile-summary ($engine_root | path join "tests" "fixtures" "Brewfile.comments")) "1 formula, 1 cask, 1 tap" "Brewfile summary counts every kind"
  assert eq (brewfile-summary ($engine_root | path join "tests" "fixtures" "Brewfile.empty")) "0 entries" "Brewfile summary of an empty file"
  assert eq (parse-outdated-names "git 2.47.1 < 2.48.0\nfish 3.7.1 < 3.7.2" [git fish]) [git fish] "outdated names parse the old format"
  assert eq (parse-outdated-names "git (installed: 2.47.1) != 2.48.0" [git]) [git] "outdated names parse the new format"
  assert eq (parse-outdated-names "git 2.47.1 < 2.48.0\nfish 3.7.1 < 3.7.2" [fish]) [fish] "outdated names filter to the requested packages"
  assert eq (parse-outdated-names "" [git]) [] "outdated names of empty output"
  assert eq (parse-outdated-names "git 2.47.1 < 2.48.0" []) [] "outdated names without requested packages"
}

# Homebrew mirror environment wiring and its configuration validation.
def test-homebrew-env [
  state_root: path # Private state template root.
] {
  let config = (load-config $state_root [personal])
  assert eq (homebrew-env $config.software.homebrew) {} "homebrew env defaults to empty"
  assert eq (homebrew-mirror-label {}) "" "no mirror label without a Homebrew environment"
  assert eq (homebrew-mirror-label {HOMEBREW_BOTTLE_DOMAIN: "https://mirrors.ustc.edu.cn/homebrew-bottles"}) "ustc (mirrors.ustc.edu.cn)" "ustc mirror label"
  assert eq (homebrew-mirror-label {HOMEBREW_BOTTLE_DOMAIN: "https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles"}) "tuna (mirrors.tuna.tsinghua.edu.cn)" "tuna mirror label"
  assert eq (homebrew-mirror-label {HOMEBREW_API_DOMAIN: "https://mirrors.ustc.edu.cn/homebrew-bottles/api"}) "ustc (mirrors.ustc.edu.cn)" "mirror label recognizes any mirror variable"
  assert eq (homebrew-mirror-label {HOMEBREW_BOTTLE_DOMAIN: "https://mirrors.example.com/bottles"}) "custom (https://mirrors.example.com/bottles)" "custom mirror label"
  let mirrored = ($config | upsert software.homebrew.env {
    "HOMEBREW_BOTTLE_DOMAIN": "https://mirrors.ustc.edu.cn/homebrew-bottles"
    "HOMEBREW_API_DOMAIN": "https://mirrors.ustc.edu.cn/homebrew-bottles/api"
  })
  assert ((validate-config $state_root $mirrored) | is-empty) "homebrew env record validates"
  assert eq (homebrew-env $mirrored.software.homebrew).HOMEBREW_BOTTLE_DOMAIN "https://mirrors.ustc.edu.cn/homebrew-bottles" "homebrew env mirrors the configuration"
  let invalid_env = ($config | upsert software.homebrew.env {HOMEBREW_BOTTLE_DOMAIN: [https]})
  assert ((validate-config $state_root $invalid_env) | any {|issue| $issue.area == homebrew and ($issue.message | str contains "values must be strings") }) "homebrew env rejects non-string values"
  let invalid_shape = ($config | upsert software.homebrew.env ["https://example.com"])
  assert ((validate-config $state_root $invalid_shape) | any {|issue| $issue.area == homebrew and ($issue.message | str contains "must be a record") }) "homebrew env rejects non-record shapes"
  let invalid_name = ($config | upsert software.homebrew.env {"FOO BAR": "https://example.com"})
  assert ((validate-config $state_root $invalid_name) | any {|issue| $issue.area == homebrew and ($issue.message | str contains "valid environment variable names") }) "homebrew env rejects invalid variable names"
}

# Persistent Homebrew mirror snippets: one snippet per shell, each exporting
# the configured environment, and none when the environment is empty.
def test-homebrew-shell-snippets [
  state_root: path # Private state template root.
] {
  let config = (load-config $state_root [personal])
  let base_snippets = (homebrew-shell-snippets $config)
  assert eq ($base_snippets | length) 0 "no snippets without a Homebrew environment"
  let mirrored = ($config | upsert software.homebrew.env {
    "HOMEBREW_API_DOMAIN": "https://mirrors.ustc.edu.cn/homebrew-bottles/api"
    "HOMEBREW_BOTTLE_DOMAIN": "https://mirrors.ustc.edu.cn/homebrew-bottles"
    "HOMEBREW_TOKEN": "a'b"
    "HOMEBREW_QUOTE": "a\"b"
  })
  let snippets = (homebrew-shell-snippets $mirrored)
  assert eq ($snippets | length) 4 "one snippet per shell"
  # Dry runs must never create, modify, or delete snippet files, whether or
  # not a previous real restore already wrote them.
  let target = ($nu.home-dir | path join ".local" "share" "reseed" "shell" "reseed-homebrew-env.sh")
  let before = (if ($target | path exists) { open --raw $target } else { null })
  homebrew-persist-env $mirrored --dry-run
  homebrew-persist-env $config --dry-run
  let after = (if ($target | path exists) { open --raw $target } else { null })
  assert eq $after $before "persist dry-run leaves snippets untouched"
  # A disabled Homebrew must also be side-effect free in dry-run (and would
  # remove stale snippets on a real run).
  let disabled = ($mirrored | upsert software.homebrew.enabled false)
  homebrew-persist-env $disabled --dry-run
  let after_disabled = (if ($target | path exists) { open --raw $target } else { null })
  assert eq $after_disabled $after "persist dry-run with disabled Homebrew leaves snippets untouched"
  assert eq ($snippets | get path | each {|path| $path | path basename }) [
    reseed-homebrew-env.nu
    reseed-homebrew-env.fish
    reseed-homebrew-env.sh
    reseed-homebrew-env.ps1
  ] "snippet filenames"
  assert (($snippets | get path | any {|path| ($path | path dirname | path basename) == "autoload" })) "Nushell snippet uses the vendor autoload"
  assert (($snippets | get path | any {|path| ($path | path dirname | path basename) == "conf.d" })) "Fish snippet uses conf.d"
  with-temp-dir "reseed-xdg-test.XXXXXXXX" {|xdg_config_home|
    let xdg_snippets = (with-env {XDG_CONFIG_HOME: $xdg_config_home} { homebrew-shell-snippets $mirrored })
    let fish_path = ($xdg_snippets | get path | where {|path| ($path | path basename) == "reseed-homebrew-env.fish" } | first)
    assert (($fish_path | into string) | str starts-with ($xdg_config_home | into string)) "Fish snippet honors XDG_CONFIG_HOME"
  }
  let all_lines = ($snippets | get lines | flatten)
  assert ($all_lines | any {|line| $line == "$env.HOMEBREW_API_DOMAIN = \"https://mirrors.ustc.edu.cn/homebrew-bottles/api\"" }) "Nushell snippet exports the environment"
  assert ($all_lines | any {|line| $line == "set -gx HOMEBREW_BOTTLE_DOMAIN 'https://mirrors.ustc.edu.cn/homebrew-bottles'" }) "Fish snippet exports the environment"
  assert ($all_lines | any {|line| $line == "export HOMEBREW_BOTTLE_DOMAIN='https://mirrors.ustc.edu.cn/homebrew-bottles'" }) "POSIX snippet exports the environment"
  assert ($all_lines | any {|line| $line == "$env:HOMEBREW_API_DOMAIN = 'https://mirrors.ustc.edu.cn/homebrew-bottles/api'" }) "PowerShell snippet exports the environment"
  assert ($all_lines | any {|line| $line == "set -gx HOMEBREW_TOKEN 'a\\'b'" }) "Fish snippet escapes single quotes"
  assert ($all_lines | any {|line| $line == "export HOMEBREW_TOKEN='a'\\''b'" }) "POSIX snippet escapes single quotes"
  assert ($all_lines | any {|line| $line == "$env:HOMEBREW_TOKEN = 'a''b'" }) "PowerShell snippet escapes single quotes"
  assert ($all_lines | any {|line| $line == "$env.HOMEBREW_TOKEN = \"a'b\"" }) "Nushell snippet keeps single quotes in double-quoted literals"
  assert ($all_lines | any {|line| $line == "$env.HOMEBREW_QUOTE = \"a\\\"b\"" }) "Nushell snippet escapes double quotes"
  assert ($all_lines | any {|line| $line == "set -gx HOMEBREW_QUOTE 'a\"b'" }) "Fish snippet keeps double quotes literal"
  assert ($all_lines | any {|line| $line == "export HOMEBREW_QUOTE='a\"b'" }) "POSIX snippet keeps double quotes literal"
  assert ($all_lines | any {|line| $line == "$env:HOMEBREW_QUOTE = 'a\"b'" }) "PowerShell snippet keeps double quotes literal"
}

# The ordered restore plan and its verification scope.
def test-workflow-plan [
  state_root: path # Private state template root.
] {
  let config = (load-config $state_root [personal])
  let plan = (workflow-plan $state_root $config)
  assert eq ($plan.stage) [system-packages portable-tools macos-finder configuration snapshots verification] "restore dependency order"
  assert eq ($plan.order) [1 2 3 4 5 6] "restore ordering is stable"
  let offline_plan = (workflow-plan $state_root $config --skip-software)
  assert eq ($offline_plan.enabled | first 2) [false false] "configuration-only restore skips software"
  assert eq (workflow-verification-tools) [bootstrap winget homebrew mise chezmoi kopia finder] "full verification scope"
  assert eq (workflow-verification-tools --skip-software) [bootstrap chezmoi kopia finder] "offline verification scope"
}

# Tool observation: dry-run behavior, filenames, and the unknown-manager
# extension point.
def test-tooling-observations [
  _engine_root: path # Retained for the common test function interface.
  state_root: path # Private state template root.
] {
  let config = (load-config $state_root [personal])
  with-temp-dir "reseed-tooling-test.XXXXXXXX" {|sandbox|
    let dry_state = ($sandbox | path join "state")
    let tooling_config = ($config
      | upsert state_dir ($dry_state | into string)
      | upsert observations.tool_managers [cargo pnpm bun uv npm yarn])
    let observations = (tooling-observe $state_root $tooling_config --dry-run)
    assert eq ($observations.manager) [cargo pnpm bun uv uv npm yarn] "tool observation order"
    assert ($observations | where available | all {|item| $item.ok and $item.detail == "would capture" }) "available tool observations support dry run"
    assert eq ($observations.observation | each {|path| $path | path basename }) [
      cargo-install.txt
      pnpm-global.json
      bun-global-package.json
      uv-tools.txt
      uv-python.json
      npm-global.json
      yarn-global.jsonl
    ] "tool observation filenames"
    assert (not ($dry_state | path exists)) "tool observation dry run writes no state"

    let unknown = (tooling-observe $state_root ($tooling_config | upsert observations.tool_managers [future-manager]) --dry-run | first)
    assert eq $unknown.ok false "unknown observation manager is reported"
    assert ($unknown.migration | str contains "add an integration") "unknown observation manager reserves an extension point"
  }
}

# Mise command construction and the shared managed-tool environment, plus
# the generated shell adapter content.
def test-mise-commands [
  state_root: path # Private state template root.
] {
  let config = (load-config $state_root [personal])
  assert eq (mise-exec-args ($state_root | path join "mise.toml") "pnpm" ["--version"]) ["-C" ($state_root | into string) "exec" "--" "pnpm" "--version"] "mise exec command construction"
  assert eq (mise-exec-args ($state_root | path join "mise.work.toml") "uv" ["--version"]) ["-C" ($state_root | into string) "-E" "work" "exec" "--" "uv" "--version"] "mise environment command construction"
  assert eq (mise-shell-config $state_root $config) (($state_root | path join "mise.toml") | path expand --no-symlink) "mise shell config resolves from configuration"
  assert eq ((managed-tool-environment).PNPM_HOME) (managed-bin-dir | path dirname | into string) "PNPM_HOME uses managed root so pnpm's global bin dir is the managed bin directory"
  assert eq ((managed-tool-environment).UV_TOOL_BIN_DIR) (managed-bin-dir | into string) "UV_TOOL_BIN_DIR uses managed bin directory"
  assert eq ((managed-tool-environment).YARN_PREFIX) (managed-bin-dir | path dirname | into string) "YARN_PREFIX uses managed root"
  assert eq ((managed-tool-environment).BUN_INSTALL) (managed-bin-dir | path dirname | into string) "BUN_INSTALL uses managed root"
  assert eq ((managed-tool-environment).CARGO_INSTALL_ROOT) (managed-bin-dir | path dirname | into string) "Cargo installs use managed root"
  assert (((managed-tool-environment).PATH | first) == (managed-bin-dir | into string)) "PATH prepends managed bin directory"
  assert eq (cargo-binstall-args (managed-bin-dir | path dirname) [ripgrep]) ["--no-confirm" "--disable-telemetry" "--root" (managed-bin-dir | path dirname | into string) ripgrep] "cargo-binstall uses explicit shared root"
}

# Execute the shell generator in an isolated home, repeat it to exercise
# idempotence, and source the generated Nushell environment.
def test-shell-generation-in [
  sandbox: path # Temporary directory containing the isolated environment.
  state_root: path # State template providing a valid mise config.
] {
  let test_state = ($sandbox | path join "State Root's Config")
  let home = ($sandbox | path join "Home's Spaces")
  let data = ($sandbox | path join "Nushell Data")
  let cargo_home = ($sandbox | path join "Cargo Home's Spaces")
  let xdg_config_home = ($sandbox | path join "XDG Config's Spaces")
  let brew_prefix = ($sandbox | path join "Homebrew Prefix's Spaces")
  let mise_config = ($test_state | path join "mise.toml")
  let starship_source = ($sandbox | path join "starship-source.nu")
  let mise_source = ($sandbox | path join "mise-source.nu")
  mkdir $test_state
  mkdir $home
  mkdir ($cargo_home | path join "bin")
  mkdir ($brew_prefix | path join "bin") ($brew_prefix | path join "sbin")
  cp ($state_root | path join "mise.toml") $mise_config
  "# isolated Starship activation\n" | save $starship_source
  "# isolated mise activation\n$env.MISE_SHELL = 'nu'\n" | save $mise_source
  "export RESEED_PROFILE_SENTINEL=1  \n\n" | save ($home | path join ".bashrc")

  let legacy_dir = ($data | path join "vendor" "autoload")
  mkdir $legacy_dir
  "legacy\n" | save ($legacy_dir | path join "mise.nu")
  "legacy\n" | save ($legacy_dir | path join "reseed-managed-tools.nu")
  let script = ($state_root | path join "scripts" "configure-shells.nu")
  let args = [
    "--no-config-file" ($script | into string)
    "--home" ($home | into string)
    "--data-dir" ($data | into string)
    "--mise-config" ($mise_config | into string)
    "--state-root" ($test_state | into string)
    "--cargo-home" ($cargo_home | into string)
    "--xdg-config-home" ($xdg_config_home | into string)
    "--starship-init-source" ($starship_source | into string)
    "--mise-activation-source" ($mise_source | into string)
  ]
  with-env {HOMEBREW_PREFIX: $brew_prefix} {
    run-command nu $args --quiet --capture | ignore
    run-command nu $args --quiet --capture | ignore
  }

  let autoload = ($data | path join "vendor" "autoload")
  let nu_environment = ($autoload | path join "reseed-10-environment.nu")
  let nu_activation = ($autoload | path join "reseed-20-mise.nu")
  let shell_dir = ($home | path join ".local" "share" "reseed" "shell")
  let bash_adapter = ($shell_dir | path join "reseed-managed-tools.bash")
  let zsh_adapter = ($shell_dir | path join "reseed-managed-tools.zsh")
  let posix_adapter = ($shell_dir | path join "reseed-managed-tools.sh")
  let powershell_adapter = ($shell_dir | path join "reseed-managed-tools.ps1")
  let fish_adapter = ($xdg_config_home | path join "fish" "conf.d" "reseed-managed-tools.fish")
  assert ($nu_environment | path exists) "Nushell environment adapter is generated"
  assert ($nu_activation | path exists) "Nushell activation adapter is generated"
  assert (not (($autoload | path join "mise.nu") | path exists)) "legacy mise autoload is removed"
  assert (not (($autoload | path join "reseed-managed-tools.nu") | path exists)) "legacy environment autoload is removed"

  let bash = (open --raw $bash_adapter)
  let zsh = (open --raw $zsh_adapter)
  let dispatch = (open --raw $posix_adapter)
  let powershell = (open --raw $powershell_adapter)
  let fish = (open --raw $fish_adapter)
  assert ($bash | str contains "mise activate bash") "Bash uses Bash activation"
  assert (not ($bash | str contains "mise activate zsh")) "Bash does not install Zsh hooks"
  assert ($zsh | str contains "mise activate zsh") "Zsh uses Zsh activation"
  assert (not ($zsh | str contains "mise activate bash")) "Zsh does not install Bash hooks"
  assert (($dispatch | str contains "mise activate bash") and ($dispatch | str contains "mise activate zsh")) "compatibility adapter dispatches by shell"
  assert (($bash | str index-of "reseed_prepend_path") < ($bash | str index-of "mise activate bash")) "mise activation owns final PATH precedence"
  let posix_cargo_bin = (($cargo_home | path join "bin" | into string) | str replace --all "\\" "/" | str replace --all "'" "'\\''")
  assert ($bash | str contains $posix_cargo_bin) "Bash uses configured Cargo home"
  let posix_brew_bin = (($brew_prefix | path join "bin" | into string) | str replace --all "\\" "/" | str replace --all "'" "'\\''")
  assert ($bash | str contains $posix_brew_bin) "Bash persists declared Homebrew prefix"
  let powershell_mise_config = (($mise_config | into string) | str replace --all "'" "''")
  assert ($powershell | str contains $powershell_mise_config) "PowerShell uses selected mise config"
  assert ($fish | str contains (($mise_config | into string) | str replace --all "\\" "/")) "Fish uses selected mise config"
  if (command-exists pwsh) {
    let ps_path = (($powershell_adapter | into string) | str replace --all "'" "''")
    let ps_command = "[scriptblock]::Create((Get-Content -Raw -LiteralPath '" + $ps_path + "')) | Out-Null"
    run-command pwsh ["-NoProfile" "-Command" $ps_command] --quiet --capture | ignore
  }

  let bash_profile = (open --raw ($home | path join ".bashrc"))
  let zsh_profile = (open --raw ($home | path join ".zshrc"))
  let powershell_profile = if $nu.os-info.name == "windows" {
    $home | path join "Documents" "PowerShell" "Microsoft.PowerShell_profile.ps1"
  } else {
    $home | path join ".config" "powershell" "Microsoft.PowerShell_profile.ps1"
  }
  assert eq ($bash_profile | split row "# >>> Reseed managed tools >>>" | length) 2 "Bash loader block is idempotent"
  assert ($bash_profile | str starts-with "export RESEED_PROFILE_SENTINEL=1  \n\n") "Bash loader preserves unmanaged profile content"
  assert eq ($zsh_profile | split row "# >>> Reseed managed tools >>>" | length) 2 "Zsh loader block is idempotent"
  assert eq ((open --raw $powershell_profile) | split row "# >>> Reseed managed tools >>>" | length) 2 "PowerShell loader block is idempotent"
  let nu_literal = ($nu_environment | into string | to nuon)
  let probe = (run-command nu ["--no-config-file" "-c" $"source ($nu_literal); print $env.MISE_GLOBAL_CONFIG_FILE"] --quiet --capture)
  assert eq ($probe.stdout | str trim) ($mise_config | path expand --no-symlink | into string) "generated Nushell environment exports selected config"

  let stale_environment = ($autoload | path join "reseed-managed-tools.nu")
  let stale_activation = ($autoload | path join "mise.nu")
  let stale_starship = ($autoload | path join "starship.nu")
  "stale\n" | save --force $stale_environment
  "stale\n" | save --force $stale_activation
  let missing_source = ($sandbox | path join "missing-mise-source.nu")
  let failed_args = [
    "--no-config-file" ($script | into string)
    "--home" ($home | into string)
    "--data-dir" ($data | into string)
    "--mise-config" ($mise_config | into string)
    "--state-root" ($test_state | into string)
    "--cargo-home" ($cargo_home | into string)
    "--xdg-config-home" ($xdg_config_home | into string)
    "--starship-init-source" ($starship_source | into string)
    "--mise-activation-source" ($missing_source | into string)
  ]
  let failed = (run-command nu $failed_args --quiet --capture --allow-failure)
  assert ($failed.exit_code != 0) "shell generation reports activation failure"
  assert (not ($stale_environment | path exists)) "failed generation removes stale Nushell environment"
  assert (not ($stale_activation | path exists)) "failed generation removes stale Nushell activation"
  assert (not ($stale_starship | path exists)) "failed generation removes stale Starship activation"
}

def test-shell-generation [
  _engine_root: path # Retained for the common test function interface.
  state_root: path # State template providing a valid mise config.
] {
  with-temp-dir "reseed-shell-test.XXXXXXXX" {|sandbox|
    test-shell-generation-in $sandbox $state_root
  }
}

# Re-seeding engine-owned template files into an existing state repository.
def test-sync-engine-files [
  engine_root: path # Engine root providing the template.
  state_root: path # State template root.
] {
  with-temp-dir "reseed-sync-test.XXXXXXXX" {|root|
    for entry in (ls --all $state_root) {
      cp --recursive $entry.name $root
    }
    rm ($root | path join "scripts" "configure-shells.nu")
    assert (not (($root | path join "scripts" "configure-shells.nu") | path exists)) "fixture starts without the generator"
    sync-engine-files $engine_root $root
    assert (($root | path join "scripts" "configure-shells.nu") | path exists) "sync re-seeds a missing generator"
    rm ($root | path join "scripts" "configure-shells.nu")
    sync-engine-files $engine_root $root --dry-run
    assert (not (($root | path join "scripts" "configure-shells.nu") | path exists)) "dry-run sync does not write"
  }
}

# The reseed:shells pre-flight reports a missing generator instead of letting
# mise fail with an opaque "File not found".
def test-shell-generator-preflight [
  engine_root: path # Engine root providing the template.
  state_root: path # State template root.
] {
  with-temp-dir "reseed-preflight-test.XXXXXXXX" {|root|
    for entry in (ls --all $state_root) {
      cp --recursive $entry.name $root
    }
    rm ($root | path join "scripts" "configure-shells.nu")
    let config = (load-config $root [personal])
    let message = (try {
      mise-configure-shells $root $config --dry-run
      ""
    } catch {|error| $error.msg? | default ($error | to nuon) })
    assert (($message | str contains "missing")) "missing generator produces a clear error"
  }
}

# Mise backend dependencies, install ordering, and package record
# normalization.
def test-mise-backends [
  engine_root: path # Engine root for fixture paths.
  state_root: path # Private state template root.
] {
  let config = (load-config $state_root [personal])
  let backend_path = ($engine_root | path join "tests" "fixtures" "mise.backends.toml")
  let complete_backend_path = ($engine_root | path join "tests" "fixtures" "mise.complete.toml")
  assert eq (mise-missing-backend-dependencies $backend_path | get tool) [node rust python] "mise backend dependency validation"
  assert eq (mise-backend-dependencies $complete_backend_path | get tool) [node rust python] "mise dependency ordering"
  let missing_dependency_config = ($config
    | upsert software.mise.configs [tests/fixtures/mise.backends.toml]
    | upsert software.mise.manager_config tests/fixtures/mise.backends.toml)
  assert ((validate-config $engine_root $missing_dependency_config) | any {|issue| $issue.area == mise and ($issue.message | str contains "requires 'node'") }) "config reports missing npm backend dependency"
  let dependency_config = ($config
    | upsert software.mise.configs [tests/fixtures/mise.complete.toml]
    | upsert software.mise.manager_config tests/fixtures/mise.complete.toml)
  assert eq (mise-install-plan $engine_root $dependency_config | get tool) [node rust python null] "mise install dependency command order"
  assert eq (uv-package-record "ruff") {spec: ruff name: ruff version: null commands: []} "unversioned uv package"
  assert eq (uv-package-record "ruff==0.12.0") {spec: "ruff==0.12.0" name: ruff version: "0.12.0" commands: []} "pinned uv package"
  assert eq (pnpm-package-record "@biomejs/biome") {spec: "@biomejs/biome" name: "@biomejs/biome" version: null commands: []} "unversioned pnpm package"
  assert eq (pnpm-package-record "@biomejs/biome@2.1.0") {spec: "@biomejs/biome@2.1.0" name: "@biomejs/biome" version: "2.1.0" commands: []} "pinned pnpm package"
  assert eq (node-package-record "@biomejs/biome@2.1.0" [biome]) {spec: "@biomejs/biome@2.1.0" name: "@biomejs/biome" version: "2.1.0" commands: [biome]} "node package command mapping"
}

# Package specifier parsing and per-manager install/update semantics.
def test-spec-parsing [] {
  assert eq (node-spec-parse "@biomejs/biome@2.1.0") {name: "@biomejs/biome" version: "2.1.0"} "node spec parsing with version"
  assert eq (node-spec-parse "pkg") {name: pkg version: null} "node spec parsing without version"
  assert eq (node-spec-parse "pkg@latest") {name: pkg version: latest} "node spec parsing with tag"
  assert eq (node-spec-parse "pkg@npm:alias") null "node spec rejects npm aliases"
  assert eq (node-spec-parse "pkg@>=1.0") null "node spec rejects version ranges"
  assert eq (node-spec-parse "pkg@1.0.0@2.0.0") null "node spec rejects malformed versions"
  assert eq (uv-spec-parse "ruff==0.12.0") {name: ruff version: "0.12.0"} "uv spec parsing with version"
  assert eq (uv-spec-parse "ruff") {name: ruff version: null} "uv spec parsing without version"
  assert eq (uv-spec-parse "ruff~=0.1") null "uv spec rejects version ranges"
  assert eq (uv-spec-parse "ruff>=1.0") null "uv spec rejects comparison operators"
  assert eq (node-manager-install-args pnpm "pkg") [add --global pkg] "pnpm install semantics"
  assert eq (node-manager-install-args yarn "pkg") [global add pkg] "yarn install semantics"
  assert eq (node-manager-install-args bun "pkg") [add --global pkg] "bun install semantics"
  assert eq (node-manager-update-args yarn {spec: pkg name: pkg version: null commands: []}) [global upgrade --latest pkg] "yarn update semantics"
  assert eq (node-manager-update-args bun {spec: pkg name: pkg version: null commands: []}) [update --global pkg] "bun update semantics"
  assert eq (node-yarn-major-version "1.22.19") 1 "yarn 1 major version"
  assert eq (node-yarn-major-version "4.1.0") 4 "yarn 4 major version"
  assert eq (node-yarn-major-version "unparseable") 0 "unparseable yarn version defaults to 0"
}

# Versioned manifests, invalid manifests, and unsupported specifier
# rejection at read time and validation time.
def test-manifest-validation [
  engine_root: path # Engine root for fixture paths.
  state_root: path # Private state template root.
] {
  let config = (load-config $state_root [personal])
  let versioned_uv_config = ($config | upsert software.mise.uv.manifests [tests/fixtures/uv-versioned.nuon])
  let versioned_pnpm_config = ($config | upsert software.mise.pnpm.manifests [tests/fixtures/pnpm-versioned.nuon])
  assert eq (uv-packages $engine_root $versioned_uv_config) ["ruff==0.12.0"] "versioned uv manifest schema"
  assert eq (pnpm-packages $engine_root $versioned_pnpm_config) ["@biomejs/biome@2.1.0"] "versioned pnpm manifest schema"
  let invalid_manager_manifest_config = ($config | upsert software.mise.uv.manifests [tests/fixtures/manager-invalid.nuon])
  assert ((validate-config $engine_root $invalid_manager_manifest_config) | any {|issue| $issue.area == uv and ($issue.message | str contains "command list") }) "manager command schema validation"
  let invalid_uv_spec_config = ($config | upsert software.mise.uv.manifests [tests/fixtures/uv-invalid-spec.nuon])
  assert ((validate-config $engine_root $invalid_uv_spec_config) | any {|issue| $issue.area == uv and ($issue.message | str contains "Unsupported package specifier") }) "uv manifest rejects unsupported specifiers"
  let invalid_node_spec_config = ($config
    | upsert software.mise.bun.enabled true
    | upsert software.mise.bun.manifests [tests/fixtures/node-invalid-spec.nuon])
  assert ((validate-config $engine_root $invalid_node_spec_config) | any {|issue| $issue.area == bun and ($issue.message | str contains "Unsupported package specifier") }) "node manifest rejects unsupported specifiers"
  assert (try { uv-entries $engine_root $invalid_uv_spec_config; false } catch { true }) "uv entries reject unsupported specifiers"
  assert (try { node-manager-entries $engine_root $invalid_node_spec_config bun; false } catch { true }) "node manager entries reject unsupported specifiers"
}

# Inventory output parsing for every package manager.
def test-inventory-parsing [] {
  assert eq (parse-uv-inventory "ruff v0.12.0\nother output") [{name: ruff version: "0.12.0"}] "uv inventory parsing"
  let pnpm_inventory = (parse-pnpm-inventory ({dependencies: {"@biomejs/biome": {version: "2.1.0"} ruff: {version: "1.0.0"}}}))
  assert eq $pnpm_inventory [{name: "@biomejs/biome" version: "2.1.0"} {name: ruff version: "1.0.0"}] "pnpm inventory parsing"
  assert eq (parse-node-dependency-inventory ({dependencies: {"@biomejs/biome": {version: "2.1.0"}}})) [{name: "@biomejs/biome" version: "2.1.0"}] "node dependency inventory parsing"
  assert eq (parse-yarn-inventory '{"type":"tree","data":[{"name":"@biomejs/biome@2.1.0"},{"name":"ruff@1.0.0"}]}') [{name: "@biomejs/biome" version: "2.1.0"} {name: ruff version: "1.0.0"}] "yarn inventory parsing"
  assert eq (parse-bun-inventory "C:\\bun\\install\\global node_modules (2)\n-- @biomejs/biome@2.1.0\n-- ruff@1.0.0") [{name: "@biomejs/biome" version: "2.1.0"} {name: ruff version: "1.0.0"}] "bun inventory parsing"
}

# Missing-package detection for pinned and unpinned desired states, plus
# declared-command verification.
def test-missing-packages [] {
  let desired_unpinned = [
    {spec: ruff name: ruff version: null}
  ]
  let desired_pinned = [
    {spec: "ruff==0.12.0" name: ruff version: "0.12.0"}
  ]
  let installed_version = [{name: ruff version: "0.12.0"}]
  assert eq (uv-missing-packages $desired_unpinned [{name: ruff version: "0.11.0"}]) [] "unpinned uv presence check"
  assert eq (uv-missing-packages $desired_pinned $installed_version) [] "pinned uv version check"
  assert eq (uv-missing-packages $desired_pinned [{name: ruff version: "0.11.0"}] | get spec) ["ruff==0.12.0"] "pinned uv mismatch"
  assert eq (pnpm-missing-packages [{spec: "@biomejs/biome" name: "@biomejs/biome" version: null}] [{name: "@biomejs/biome" version: "1.0.0"}]) [] "unpinned pnpm presence check"
  assert eq (pnpm-missing-packages [{spec: "@biomejs/biome@2.1.0" name: "@biomejs/biome" version: "2.1.0"}] [{name: "@biomejs/biome" version: "1.0.0"}] | get spec) ["@biomejs/biome@2.1.0"] "pinned pnpm mismatch"
  assert eq (node-manager-missing-packages [{spec: "@biomejs/biome" name: "@biomejs/biome" version: null commands: [biome]}] [{name: "@biomejs/biome" version: "1.0.0"}]) [] "unpinned node manager presence check"
  assert eq (managed-command-checks pnpm [{spec: "@biomejs/biome" name: "@biomejs/biome" version: null commands: [biome]}] | get check) ["managed binary: biome"] "declared command verification"
}

# Mise configuration validation: manager config selection, config naming,
# and task file presence.
def test-mise-config-validation [
  state_root: path # Private state template root.
] {
  let config = (load-config $state_root [personal])
  let invalid_manager_config = ($config | upsert software.mise.manager_config missing.toml)
  assert ((validate-config $state_root $invalid_manager_config) | any {|issue| $issue.area == mise and ($issue.message | str contains "manager_config") }) "manager config selection validation"
  let invalid_manager_config_type = ($config | upsert software.mise.manager_config 42)
  assert ((validate-config $state_root $invalid_manager_config_type) | any {|issue| $issue.area == mise and ($issue.message | str contains "must be a string") }) "manager config type validation"
  let invalid_shell_config = ($config | upsert software.mise.shell_config missing.toml)
  assert ((validate-config $state_root $invalid_shell_config) | any {|issue| $issue.area == mise and ($issue.message | str contains "shell_config") }) "shell config selection validation"
  let invalid_shell_config_type = ($config | upsert software.mise.shell_config 42)
  assert ((validate-config $state_root $invalid_shell_config_type) | any {|issue| $issue.area == mise and ($issue.message | str contains "must be a string") }) "shell config type validation"
  assert ((mise-manager-config $state_root $config) | path exists) "manager config resolves to an existing file"

  let invalid_mise = ($config | upsert software.mise.configs [tools.custom.toml])
  let invalid_issues = (validate-config $state_root $invalid_mise)
  assert ($invalid_issues | any {|issue| $issue.area == mise and ($issue.message | str contains "Unsupported config name") }) "mise config names are validated"
  let missing_task = ($config | upsert software.mise.task_files [scripts/missing.nu])
  assert ((validate-config $state_root $missing_task) | any {|issue| $issue.area == mise and ($issue.message | str contains "Missing mise task file") }) "mise task files are validated"
  # An enabled manager whose tool is missing from the manager mise config warns
  # with the exact [tools] entry to add; declared managers stay quiet.
  let undeclared_bun = ($config | upsert software.mise.bun {enabled: true manifests: [packages/node/bun/global.nuon] update: true})
  let bun_issues = (validate-config $state_root $undeclared_bun)
  assert (($bun_issues | where level == error) | is-empty) "enabling an undeclared manager validates without errors"
  assert ($bun_issues | any {|issue| $issue.level == warning and $issue.area == bun and ($issue.message | str contains "aqua:oven-sh/bun") }) "enabling an undeclared manager warns with the aqua tool to declare"
  assert ((validate-config $state_root $config | where level == warning) | is-empty) "declared managers produce no warnings"
}

# Checkpoint scoping and desired-state fingerprints.
def test-checkpoints [
  engine_root: path # Engine root.
  state_root: path # Private state template root.
] {
  let config = (load-config $state_root [personal])
  let checkpoint = (checkpoint-path $config | path basename)
  assert ($checkpoint | str contains "personal") "checkpoint is profile-specific"
  let state_fingerprint = (config-fingerprint $state_root $config)
  let restore_fingerprint = (config-fingerprint $state_root $config --engine-root=$engine_root)
  assert eq ($state_fingerprint | str length) 64 "desired-state fingerprint"
  assert eq ($restore_fingerprint | str length) 64 "engine-aware restore fingerprint"
  assert ne $state_fingerprint $restore_fingerprint "engine changes invalidate restore checkpoints"
}

# The pre-commit secret guard: high-signal filename and content patterns,
# plus the repository scan and change summary over a disposable repository.
def test-secret-guard [
  engine_root: path # Engine root for disposable git repositories.
] {
  assert eq (secret-name-matches "id_ed25519") ["SSH private key"] "SSH private key filename"
  assert eq (secret-name-matches "id_ed25519_sk") ["SSH private key"] "SSH security-key private filename"
  assert eq (secret-name-matches "id_rsa.pub") [] "public SSH keys are not credentials"
  assert eq (secret-name-matches ".git-credentials") ["Git credentials"] "git credentials filename"
  assert eq (secret-name-matches ".netrc") ["netrc credentials"] "netrc filename"
  assert eq (secret-name-matches ".pypirc") ["pip credentials"] "pip credentials filename"
  assert eq (secret-name-matches "credentials") ["generic credentials"] "generic credentials filename"
  assert eq (secret-name-matches ".env") ["environment file"] "dotenv filename"
  assert eq (secret-name-matches ".env.production") ["environment file"] "environment filename"
  assert eq (secret-name-matches "gitconfig") [] "ordinary config filenames pass"
  assert ("private key" in (secret-content-matches "-----BEGIN OPENSSH PRIVATE KEY-----\nabc123")) "OpenSSH private key content"
  assert ("private key" in (secret-content-matches "-----BEGIN PGP PRIVATE KEY BLOCK-----")) "PGP private key content"
  assert ("private key" in (secret-content-matches "-----BEGIN PRIVATE KEY-----\nabc123")) "PKCS8 private key content"
  # Token payloads are assembled from fragments so no credential-shaped
  # literal appears in the repository (GitHub push protection scans diffs).
  let payload36 = "123456789012345678901234567890123456"
  assert ("GitHub token" in (secret-content-matches ("gh" + "p_" + $payload36))) "GitHub token content"
  assert ("GitHub fine-grained token" in (secret-content-matches ("github_" + "pat_" + "1234567890123456789abcdefg"))) "GitHub fine-grained token content"
  assert ("AWS access key" in (secret-content-matches ("AK" + "IA" + "1234567890ABCDEF"))) "AWS access key content"
  assert ("Google API key" in (secret-content-matches ("AI" + "za" + "12345678901234567890123456789012345"))) "Google API key content"
  assert ("Slack token" in (secret-content-matches ("xox" + "b-" + "1234567890-abcdefghij"))) "Slack token content"
  assert ("Stripe secret key" in (secret-content-matches ("sk" + "_live_" + "123456789012345678901234"))) "Stripe secret key content"
  assert ("GitLab personal access token" in (secret-content-matches ("gl" + "pat-" + "abcdefghijklmnopqrstuvwxyz1234567890"))) "GitLab token content"
  assert ("npm access token" in (secret-content-matches ("np" + "m_" + $payload36))) "npm token content"
  assert eq (secret-content-matches "nothing secret here") [] "clean content passes"

  if not (command-exists git) { return }
  with-temp-dir "reseed-secret-test.XXXXXXXX" {|scan_root|
    run-command git ["-C" $scan_root "init" "-b" "main" "-q"] --quiet | ignore
    "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAAB3NzaC1yc2E" | save --force ($scan_root | path join "id_ed25519")
    ("export GH_TOKEN=" + "gh" + "p_" + $payload36) | save --force ($scan_root | path join ".env")
    0x[00 FF 00 01] | save --raw --force ($scan_root | path join "blob.bin")
    "[user]\nname = Test" | save --force ($scan_root | path join ".gitconfig")
    run-command git ["-C" $scan_root "add" "--all"] --quiet | ignore
    let secrets = (scan-commit-secrets $scan_root)
    assert (($secrets | any {|match| $match.pattern == "SSH private key" })) "repository scan finds SSH private key files"
    assert (($secrets | any {|match| $match.pattern == "environment file" })) "repository scan finds environment files"
    assert (($secrets | any {|match| $match.pattern == "GitHub token" })) "repository scan finds token content"
    assert (not ($secrets | any {|match| ($match.path | str contains ".gitconfig") })) "repository scan ignores clean config files"
    assert (not ($secrets | any {|match| ($match.path | str contains "blob.bin") })) "repository scan skips binary files"
    let summary = (commit-change-summary $scan_root)
    assert (($summary | any {|entry| ($entry.path | str contains "id_ed25519") and $entry.size > 0B })) "commit summary lists changed files with sizes"
  }
}

# Bootstrap state sync: fast-forward an already-initialized private state root
# from the provided repository, leaving dirty, diverged, and non-repository
# roots alone and refusing a mismatched remote.
def test-git-sync [] {
  if not (command-exists git) { return }
  with-temp-dir "reseed-sync-test.XXXXXXXX" {|sandbox|
    let origin = ($sandbox | path join "origin.git")
    let seed = ($sandbox | path join "seed")
    run-command git ["init" "--bare" "-b" "main" ($origin | into string)] --quiet | ignore
    run-command git ["init" "-b" "main" ($seed | into string)] --quiet | ignore
    configure-git-identity $seed
    "scaffold\n" | save ($seed | path join "mise.toml")
    run-command git ["-C" ($seed | into string) "add" "--all"] --quiet | ignore
    run-command git ["-C" ($seed | into string) "commit" "-m" "seed"] --quiet | ignore
    run-command git ["-C" ($seed | into string) "remote" "add" "origin" ($origin | into string)] --quiet | ignore
    run-command git ["-C" ($seed | into string) "push" "-u" "origin" "main"] --quiet | ignore

    # A stale clone repairs itself once origin gains the missing desired state.
    let stale = ($sandbox | path join "stale")
    run-command git ["clone" "--branch" "main" "--single-branch" ($origin | into string) ($stale | into string)] --quiet | ignore
    configure-git-identity $stale
    assert (not (($stale | path join "config" "recovery.nuon") | path exists)) "fixture clone starts without recovery.nuon"
    mkdir ($seed | path join "config")
    "{\n  schema: 1\n}\n" | save ($seed | path join "config" "recovery.nuon")
    run-command git ["-C" ($seed | into string) "add" "--all"] --quiet | ignore
    run-command git ["-C" ($seed | into string) "commit" "-m" "add config"] --quiet | ignore
    run-command git ["-C" ($seed | into string) "push" "origin" "main"] --quiet | ignore
    git-sync $stale ($origin | into string)
    assert (($stale | path join "config" "recovery.nuon") | path exists) "sync fast-forwards the provided state"

    # Up-to-date syncs are a no-op.
    git-sync $stale ($origin | into string)
    assert (($stale | path join "config" "recovery.nuon") | path exists) "up-to-date sync keeps the state"

    # A dirty working tree is left untouched and the sync still succeeds.
    "local edit\n" | save --append ($stale | path join "mise.toml")
    git-sync $stale ($origin | into string)
    assert (open --raw ($stale | path join "mise.toml") | str contains "local edit") "dirty sync leaves local changes alone"

    # A diverged working tree warns and keeps the local commit.
    run-command git ["-C" ($stale | into string) "add" "--all"] --quiet | ignore
    run-command git ["-C" ($stale | into string) "commit" "-m" "local divergence"] --quiet | ignore
    let rival = ($sandbox | path join "rival")
    run-command git ["clone" "--branch" "main" "--single-branch" ($origin | into string) ($rival | into string)] --quiet | ignore
    configure-git-identity $rival
    "rival edit\n" | save --append ($rival | path join "mise.toml")
    run-command git ["-C" ($rival | into string) "add" "--all"] --quiet | ignore
    run-command git ["-C" ($rival | into string) "commit" "-m" "rival edit"] --quiet | ignore
    run-command git ["-C" ($rival | into string) "push" "origin" "main"] --quiet | ignore
    git-sync $stale ($origin | into string)
    let head = (run-command git ["-C" ($stale | into string) "log" "-1" "--format=%s"] --quiet --capture)
    assert eq ($head.stdout | str trim) "local divergence" "diverged sync keeps the local commit"

    # --replace adopts the remote over a committed, diverged local branch.
    git-sync $stale ($origin | into string) --replace
    let replaced_head = (run-command git ["-C" ($stale | into string) "log" "-1" "--format=%s"] --quiet --capture)
    assert eq ($replaced_head.stdout | str trim) "rival edit" "--replace adopts the remote over local commits"

    # A mismatched origin is refused instead of syncing from a different repo.
    run-command git ["-C" ($stale | into string) "remote" "set-url" "origin" "https://example.com/other.git"] --quiet | ignore
    let refused = (try {
      git-sync $stale ($origin | into string)
      ""
    } catch {|error| $error.msg? | default ($error | to nuon) })
    assert (($refused | str contains "refusing to sync")) "mismatched origin is refused"

    # A sentinel-marked root without a Git repository is skipped, not failed.
    let no_repo = ($sandbox | path join "no-repo")
    mkdir $no_repo
    ".reseed-state\n" | save ($no_repo | path join ".reseed-state")
    git-sync $no_repo ($origin | into string)
    assert (($no_repo | path join ".reseed-state") | path exists) "non-repository sync is skipped"

    # A source that is not a Git repository fails early and does not pollute
    # the local origin remote.
    let fresh = ($sandbox | path join "fresh")
    run-command git ["init" "-b" "main" ($fresh | into string)] --quiet | ignore
    configure-git-identity $fresh
    "local\n" | save ($fresh | path join "mise.toml")
    run-command git ["-C" ($fresh | into string) "add" "--all"] --quiet | ignore
    run-command git ["-C" ($fresh | into string) "commit" "-m" "local"] --quiet | ignore
    let not_a_repo = ($sandbox | path join "not-a-repo")
    mkdir $not_a_repo
    let rejected = (try {
      git-sync $fresh ($not_a_repo | into string)
      ""
    } catch {|error| $error.msg? | default ($error | to nuon) })
    assert (($rejected | str contains "Cannot read the private state repository")) "non-git source is rejected"
    let origin_probe = (run-command git ["-C" ($fresh | into string) "remote" "get-url" "origin"] --allow-failure --quiet --capture)
    assert ne $origin_probe.exit_code 0 "failed sync leaves origin unset"

    # A source whose default branch is not main is honored: git-sync resolves
    # the default branch from the remote's symbolic HEAD instead of assuming
    # main, and adopts it onto a sentinel-marked root that is not yet a
    # repository.
    let master_seed = ($sandbox | path join "master-seed")
    run-command git ["init" "-b" "master" ($master_seed | into string)] --quiet | ignore
    configure-git-identity $master_seed
    "x\n" | save ($master_seed | path join "x.txt")
    run-command git ["-C" ($master_seed | into string) "add" "--all"] --quiet | ignore
    run-command git ["-C" ($master_seed | into string) "commit" "-m" "master seed"] --quiet | ignore
    let master_origin = ($sandbox | path join "master.git")
    run-command git ["init" "--bare" ($master_origin | into string)] --quiet | ignore
    run-command git ["-C" ($master_seed | into string) "remote" "add" "origin" ($master_origin | into string)] --quiet | ignore
    run-command git ["-C" ($master_seed | into string) "push" "origin" "master"] --quiet | ignore
    let master_root = ($sandbox | path join "master-root")
    mkdir $master_root
    ".reseed-state\n" | save ($master_root | path join ".reseed-state")
    let master_sync = (git-sync $master_root ($master_origin | into string))
    assert $master_sync.synced "a non-main default branch syncs"
    let master_head = (run-command git ["-C" ($master_root | into string) "rev-parse" "--abbrev-ref" "HEAD"] --quiet --capture)
    assert eq ($master_head.stdout | str trim) "master" "git-sync adopts the remote default branch"
    assert (($master_root | path join "x.txt") | path exists) "non-main adoption copies the provided state"

    # A template-seeded root (unborn branch, no commits) adopts the provided
    # repository wholesale, preserving non-colliding untracked files.
    let seeded = ($sandbox | path join "seeded")
    run-command git ["init" "-b" "main" ($seeded | into string)] --quiet | ignore
    mkdir ($seeded | path join "config")
    ".reseed-state\n" | save ($seeded | path join ".reseed-state")
    "{ schema: 1 }\n" | save ($seeded | path join "config" "recovery.nuon")
    "user note\n" | save ($seeded | path join "user-note.txt")
    assert (not (($seeded | path join "mise.toml") | path exists)) "fixture seed starts without mise.toml"
    git-sync $seeded ($origin | into string)
    assert ((open --raw ($seeded | path join "mise.toml")) | str contains "rival edit") "unborn seed adopts the latest provided state"
    assert (($seeded | path join "user-note.txt") | path exists) "unborn seed adoption keeps non-colliding files"
    let seeded_head = (run-command git ["-C" ($seeded | into string) "log" "-1" "--format=%s"] --quiet --capture)
    assert eq ($seeded_head.stdout | str trim) "rival edit" "unborn seed adoption lands on the remote commit"

    # --replace discards uncommitted changes in favor of the provided state.
    "local replace\n" | save --append ($seeded | path join "mise.toml")
    git-sync $seeded ($origin | into string) --replace
    assert (not ((open --raw ($seeded | path join "mise.toml")) | str contains "local replace")) "--replace discards uncommitted changes"

    # A clean local branch ahead of origin (newer unpushed commits) is kept and
    # reported; --replace discards it to adopt the remote exactly.
    let ahead_clone = ($sandbox | path join "ahead")
    run-command git ["clone" "--branch" "main" "--single-branch" ($origin | into string) ($ahead_clone | into string)] --quiet | ignore
    configure-git-identity $ahead_clone
    "local ahead\n" | save --append ($ahead_clone | path join "mise.toml")
    run-command git ["-C" ($ahead_clone | into string) "add" "--all"] --quiet | ignore
    run-command git ["-C" ($ahead_clone | into string) "commit" "-m" "ahead commit"] --quiet | ignore
    let ahead_result = (git-sync $ahead_clone ($origin | into string))
    assert $ahead_result.synced "ahead sync reports success"
    assert eq $ahead_result.status ahead "ahead sync reports the ahead status"
    let ahead_head = (run-command git ["-C" ($ahead_clone | into string) "log" "-1" "--format=%s"] --quiet --capture)
    assert eq ($ahead_head.stdout | str trim) "ahead commit" "ahead sync keeps the newer local commit"
    git-sync $ahead_clone ($origin | into string) --replace
    let replaced_ahead_head = (run-command git ["-C" ($ahead_clone | into string) "log" "-1" "--format=%s"] --quiet --capture)
    assert eq ($replaced_ahead_head.stdout | str trim) "rival edit" "--replace discards ahead local commits"
  }
}

# init --remote-url adopts the remote state onto a fresh seed, so attaching a
# private remote actually pulls the private state in instead of leaving the
# template scaffold in place.
def test-init-adopt [
  engine_root: path # Engine root providing the template.
] {
  if not (command-exists git) { return }
  with-temp-dir "reseed-init-adopt.XXXXXXXX" {|sandbox|
    let origin = ($sandbox | path join "origin.git")
    run-command git ["init" "--bare" "-b" "main" ($origin | into string)] --quiet | ignore
    let seed = ($sandbox | path join "seed")
    mkdir $seed
    for entry in (ls --all ($engine_root | path join "templates" "state")) {
      cp --recursive $entry.name $seed
    }
    run-command git ["-C" ($seed | into string) "init" "-b" "main"] --quiet | ignore
    configure-git-identity $seed
    run-command git ["-C" ($seed | into string) "add" "--all"] --quiet | ignore
    run-command git ["-C" ($seed | into string) "commit" "-m" "adopted state"] --quiet | ignore
    run-command git ["-C" ($seed | into string) "remote" "add" "origin" ($origin | into string)] --quiet | ignore
    run-command git ["-C" ($seed | into string) "push" "-u" "origin" "main"] --quiet | ignore
    let state_root = ($sandbox | path join "state")
    workflow-init $engine_root $state_root [] --remote-url ($origin | into string)
    let head = (run-command git ["-C" ($state_root | into string) "log" "-1" "--format=%s"] --quiet --capture)
    assert eq ($head.stdout | str trim) "adopted state" "init --remote-url adopts the remote state onto a fresh seed"
  }
}

# An incomplete, uncommitted seed is healed on re-init (missing template files
# are re-seeded, including nested config), while committed private state is
# left untouched so a deliberate file removal survives.
def test-init-reseeds-incomplete-seed [
  engine_root: path # Engine root providing the template.
] {
  if not (command-exists git) { return }
  with-temp-dir "reseed-reseed-test.XXXXXXXX" {|sandbox|
    # An unborn seed that lost config/recovery.nuon is healed by re-init.
    let seed = ($sandbox | path join "seed")
    workflow-init $engine_root $seed []
    rm ($seed | path join "config" "recovery.nuon")
    rm ($seed | path join "mise.toml")
    assert (not (($seed | path join "config" "recovery.nuon") | path exists)) "fixture seed is incomplete"
    workflow-init $engine_root $seed []
    assert (($seed | path join "config" "recovery.nuon") | path exists) "re-init re-seeds missing config/recovery.nuon"
    assert (($seed | path join "mise.toml") | path exists) "re-init re-seeds missing mise.toml"

    # Committed state is respected: missing template files are not re-added.
    let committed = ($sandbox | path join "committed")
    workflow-init $engine_root $committed []
    run-command git ["-C" ($committed | into string) "config" "user.email" "reseed@example.com"] --quiet | ignore
    run-command git ["-C" ($committed | into string) "config" "user.name" "Reseed Test"] --quiet | ignore
    run-command git ["-C" ($committed | into string) "add" "--all"] --quiet | ignore
    run-command git ["-C" ($committed | into string) "commit" "-m" "seed"] --quiet | ignore
    rm ($committed | path join "config" "profiles" "work.nuon.example")
    workflow-init $engine_root $committed []
    assert (not (($committed | path join "config" "profiles" "work.nuon.example") | path exists)) "committed state is not re-seeded"
  }
}

# The status facts stay usable when the state root is missing, Git is absent,
# or the configuration cannot be loaded: the default `reseed` summary and
# `reseed status` must never crash on an uninitialized machine.
def test-status-facts-robust [] {
  let missing = "C:\\nonexistent\\reseed-state"
  let facts = (workflow-status-facts "C:\\workspaces\\winbackup" $missing {})
  assert eq $facts.phase "uninitialized" "a missing root reports uninitialized"
  assert (not $facts.config_ok) "an unloadable configuration is reported"
  assert eq $facts.git_available (command-exists git) "git availability is reported"
  assert (not $facts.restored) "a missing root is never restored"
  let empty_git = {git: {remote: "mine" branch: "work"}}
  assert eq (repo-probe $missing $empty_git --offline).remote_name "mine" "probe honors configured remote names"
}


# After bundle/raw recovery the configured git.url must be installed as the
# named remote, so a bare `reseed sync` (no --remote-url) can fetch, merge, and
# the recommended `sync --push` actually publishes.
def test-git-url-attachment [state_root: path] {
  if not (command-exists git) { return }
  with-temp-dir "reseed-giturl.XXXXXXXX" {|sandbox|
    let origin = (make-state-origin $sandbox "giturl" $state_root)
    let bundled = (sync-clone $sandbox "giturl-bundled" $origin)
    run-command git ["-C" ($bundled | into string) "remote" "remove" "origin"] --quiet | ignore
    let bundled_head = (run-command git ["-C" ($bundled | into string) "rev-parse" "HEAD"] --quiet --capture)
    let bundle_out = ($sandbox | path join "giturl-bundle.tar.gz")
    make-state-bundle $bundled $bundle_out ($bundled_head.stdout | str trim)
    let local = ($sandbox | path join "local")
    import-state-source $local $bundle_out [personal] | ignore
    let cfg = {git: {remote: origin branch: main url: ($origin | into string)}}
    let synced = (repo-sync $local $cfg --yes)
    assert $synced.synced "a bare sync with git.url succeeds"
    let remote_url = (run-command git ["-C" ($local | into string) "remote" "get-url" "origin"] --allow-failure --quiet --capture)
    assert eq ($remote_url.stdout | str trim) ($origin | into string) "git.url is installed as the origin remote"
    "local change\n" | save --append ($local | path join "mise.toml")
    let pushed = (repo-sync $local $cfg --commit --push --yes)
    assert eq $pushed.status "pushed" "the recommended sync --push publishes after git.url attachment"
  }
}


# The bare `reseed` and `reseed status` CLI entrypoints must not crash when the
# state root is missing or the configuration cannot be loaded.
def test-cli-robustness [engine_root: path] {
  with-temp-dir "reseed-cli-test.XXXXXXXX" {|sandbox|
    let missing = ($sandbox | path join "missing-state-root")
    let script = ($engine_root | path join "reseed.nu")
    for entry in [
      {name: summary args: [$script "--state-root" ($missing | into string)]}
      {name: status args: [$script "status" "--state-root" ($missing | into string) "--offline"]}
    ] {
      let run = (run-command nu $entry.args --allow-failure --quiet --capture)
      let detail = (($run.stderr + $run.stdout) | str trim)
      assert eq $run.exit_code 0 $"the CLI ($entry.name) survives a missing state root: ($detail)"
    }
  }
}

# The pure recommendation layer: every detected phase yields a prioritized,
# copy-pasteable command, with the required restore -> setup -> sync
# progression and exact quoting of paths.
def test-recommendations [engine_root: path] {
  let context = {engine_root: ($engine_root | into string) profiles: [personal] remote_url: ""}
  let root = ($engine_root | path join "state with spaces")

  # Conflict resolution is the top priority.
  let merge_facts = {phase: merge-in-progress state_root: ($root | into string) git_available: true repository: true sentinel: true committed: true clean: false branch: main remote_url: "" ahead: null behind: null remote: {reachable: null} config_ok: true restored: false}
  let merge_recs = (recommend $merge_facts $context)
  assert eq ($merge_recs | get priority | first) 1 "merge conflicts are the top priority"
  assert (($merge_recs | get commands | first | any {|cmd| $cmd | str contains "--continue" })) "merge recommendation includes sync --continue"
  assert (($merge_recs | get commands | first | any {|cmd| $cmd | str contains "--abort" })) "merge recommendation includes sync --abort"
  assert (not ($merge_recs | get commands | first | any {|cmd| $cmd | str contains "git -C" })) "the merge recommendation does not suggest staging before resolution"
  assert (($merge_recs | get title | first) | str contains "resolving") "the merge title directs resolving and staging first"

  # Missing Git recommends installing the prerequisite.
  let no_git = {phase: no-git state_root: ($root | into string) git_available: false repository: false sentinel: false committed: false clean: null branch: "" remote_url: "" ahead: null behind: null remote: {reachable: null} config_ok: false restored: false}
  let no_git_recs = (recommend $no_git $context)
  assert eq ($no_git_recs | get priority | first) 3 "missing Git is a prerequisite recommendation"
  let git_install = ($no_git_recs | get commands | first | first)
  let expected_git_install = match (detect-os) {
    windows => "Git.Git"
    macos => "brew install git"
    _ => "install git through your system package manager"
  }
  assert ($git_install | str contains $expected_git_install) "the platform-specific Git install command is rendered"

  # Uninitialized state is repaired before anything else.
  let uninit = {phase: uninitialized state_root: ($root | into string) git_available: true repository: false sentinel: false committed: false clean: null branch: "" remote_url: "" ahead: null behind: null remote: {reachable: null} config_ok: false restored: false}
  let uninit_recs = (recommend $uninit $context)
  assert eq ($uninit_recs | get priority | first) 2 "uninitialized state is a repair priority"
  assert (($uninit_recs | get commands | first | any {|cmd| $cmd | str contains "restore --state-source" })) "repair recommends the restore import command"

  # An unborn seed is adopted or committed.
  let unborn = {phase: unborn state_root: ($root | into string) git_available: true repository: true sentinel: true committed: false clean: null branch: main remote_url: "https://example.com/state.git" ahead: null behind: null remote: {reachable: null} config_ok: true restored: false}
  let unborn_recs = (recommend $unborn $context)
  assert eq ($unborn_recs | get priority | first) 2 "an unborn seed is a repair priority"
  assert (($unborn_recs | get commands | first | any {|cmd| $cmd | str contains "--remote-url https://example.com/state.git" })) "unborn repair renders the known remote URL"

  # A dirty, never-restored machine gets the restore -> sync progression with
  # exact quoting of the state root path.
  let dirty = {phase: dirty state_root: ($root | into string) git_available: true repository: true sentinel: true committed: true clean: false branch: main remote_url: "https://example.com/state.git" ahead: 1 behind: 0 remote: {reachable: true empty: false has_branch: true} config_ok: true restored: false}
  let dirty_recs = (recommend $dirty $context)
  assert eq ($dirty_recs | get priority) [4 6] "dirty recommends restore then sync"
  assert (($dirty_recs | where priority == 4 | get title | first) | str contains "Restore") "restore recommendation title"
  assert (($dirty_recs | where priority == 6 | get title | first) | str contains "Synchronize") "sync recommendation title"
  let dirty_cmd = ($dirty_recs | where priority == 6 | get commands | first | first)
  assert ($dirty_cmd | str contains "--commit --push") "dirty sync recommends committing and pushing"
  assert ($dirty_cmd | str contains "state with spaces") "paths with spaces are rendered"
  assert ($dirty_cmd | str contains "\"") "paths with spaces are quoted"

  # An unreachable remote on a never-restored machine yields the full
  # restore -> setup -> sync progression in priority order.
  let inaccessible = {phase: inaccessible state_root: ($root | into string) git_available: true repository: true sentinel: true committed: true clean: true branch: main remote_url: "https://example.com/state.git" ahead: null behind: null remote: {reachable: false} config_ok: true restored: false}
  let inacc_recs = (recommend $inaccessible $context)
  assert eq ($inacc_recs | get priority) [4 5 6] "inaccessible recommends restore, then access setup, then sync"
  assert (($inacc_recs | get phase) == [restore access sync]) "the progression is restore -> setup -> sync"
  assert (($inacc_recs | where priority == 5 | get commands | first | any {|cmd| $cmd | str contains "setup gh" })) "access setup recommends the gh setup"

  # A synchronized, already-restored machine reports completion with no work.
  let synced = {phase: clean-synced state_root: ($root | into string) git_available: true repository: true sentinel: true committed: true clean: true branch: main remote_url: "https://example.com/state.git" ahead: 0 behind: 0 remote: {reachable: true empty: false has_branch: true} config_ok: true restored: true}
  let synced_recs = (recommend $synced $context)
  assert eq ($synced_recs | get priority) [7] "synchronized completion is the last recommendation"
  assert eq ($synced_recs | get commands | first) [] "synchronized completion has no commands"
}

# State source import: git checkouts, raw snapshots, bundle provenance,
# invalid sources, atomic failure, identical reruns, differing existing local
# state, and dry runs.
def test-import [engine_root: path, state_root: path] {
  if not (command-exists git) { return }
  let cfg = (test-git-config)
  with-temp-dir "reseed-import-test.XXXXXXXX" {|sandbox|
    # A raw snapshot imports into a fresh root and creates a committed repo.
    let src = ($sandbox | path join "source")
    mkdir $src
    for entry in (ls --all $state_root) { cp --recursive $entry.name $src }
    let dest = ($sandbox | path join "state")
    let result = (import-state-source $dest $src [personal])
    assert eq $result.status "imported" "raw snapshot imports"
    assert eq $result.kind "raw-snapshot" "raw source kind"
    assert (($dest | path join "config" "recovery.nuon") | path exists) "imported config is present"
    assert (($dest | path join ".reseed-state") | path exists) "imported sentinel is present"
    let probe = (repo-probe $dest $cfg)
    assert $probe.repository "import initializes a repository"
    assert $probe.committed "import creates a snapshot commit"

    # An identical rerun is a no-op.
    let again = (import-state-source $dest $src [personal])
    assert eq $again.status "no-op" "identical rerun is a no-op"
    assert eq $again.fingerprint $result.fingerprint "unchanged source fingerprint"

    # A source equal to the destination is refused.
    let same = (try { import-state-source $src $src [personal]; "" } catch {|e| $e.msg? | default "" })
    assert ($same | str contains "--state-source must differ") "source equal to destination is refused"

    # An invalid source fails validation and leaves the destination untouched.
    let invalid = ($sandbox | path join "invalid")
    mkdir $invalid
    "no sentinel\n" | save ($invalid | path join "x.txt")
    let rejected = (try { import-state-source $dest $invalid [personal]; "" } catch {|e| $e.msg? | default "" })
    assert ($rejected | str contains ".reseed-state") "source without a sentinel is rejected"
    assert (($dest | path join "config" "recovery.nuon") | path exists) "failed import leaves the destination untouched"
    let backups = (glob ((($sandbox | into string | str replace --all "\\" "/")) + "/.reseed-import-*"))
    assert ($backups | is-empty) "failed imports leave no staging backup behind"

    # A different source against an initialized root is refused without
    # modifying either location.
    let other = ($sandbox | path join "other")
    mkdir $other
    for entry in (ls --all $state_root) { cp --recursive $entry.name $other }
    "extra\n" | save ($other | path join "extra.txt")
    let refused = (try { import-state-source $dest $other [personal]; "" } catch {|e| $e.msg? | default "" })
    assert ($refused | str contains "Refusing") "a different source over initialized state is refused"
    assert (not (($dest | path join "extra.txt") | path exists)) "refused import does not modify the destination"

    # Dry runs validate and report without writing.
    let dry_dest = ($sandbox | path join "dry-state")
    let dry = (import-state-source $dry_dest $src [personal] --dry-run)
    assert eq $dry.status "would-import" "dry run reports the import"
    assert (not ($dry_dest | path exists)) "dry run does not create the destination"

    # A git-checkout source imports with its history, overlay modified,
    # deleted, and non-ignored untracked files.
    let git_src = ($sandbox | path join "git-source")
    mkdir $git_src
    for entry in (ls --all $state_root) { cp --recursive $entry.name $git_src }
    run-command git ["-C" ($git_src | into string) "init" "-q" "-b" "main"] --quiet | ignore
    configure-git-identity $git_src
    run-command git ["-C" ($git_src | into string) "add" "--all"] --quiet | ignore
    run-command git ["-C" ($git_src | into string) "commit" "-m" "state base"] --quiet | ignore
    "untracked note\n" | save ($git_src | path join "note.txt")
    "modified\n" | save --append ($git_src | path join "home" "dot_config" "starship.toml")
    run-command git ["-C" ($git_src | into string) "rm" "--quiet" "config/profiles/work.nuon.example"] --quiet | ignore
    let git_dest = ($sandbox | path join "git-state")
    let git_result = (import-state-source $git_dest $git_src [personal])
    assert eq $git_result.kind "git-checkout" "git checkout source detected"
    assert (($git_dest | path join "note.txt") | path exists) "untracked files are imported"
    assert ((open --raw ($git_dest | path join "home" "dot_config" "starship.toml")) | str contains "modified") "modified files are imported"
    assert (not (($git_dest | path join "config" "profiles" "work.nuon.example") | path exists)) "deleted files are removed"
    let git_head = (run-command git ["-C" ($git_dest | into string) "rev-parse" "HEAD"] --quiet --capture)
    let src_head = (run-command git ["-C" ($git_src | into string) "rev-parse" "HEAD"] --quiet --capture)
    assert eq ($git_head.stdout | str trim) ($src_head.stdout | str trim) "git checkout import keeps the source history"
    assert (not (($git_dest | path join ".git") | path join "objects" | path exists | false)) "git history is imported"
    assert ((open --raw ($git_src | path join "note.txt")) | str contains "untracked note") "the source is left byte-for-byte unchanged"

    # A bundle source retains its state_revision provenance.
    let committed = ($sandbox | path join "committed")
    mkdir $committed
    for entry in (ls --all $state_root) { cp --recursive $entry.name $committed }
    run-command git ["-C" ($committed | into string) "init" "-q" "-b" "main"] --quiet | ignore
    configure-git-identity $committed
    run-command git ["-C" ($committed | into string) "add" "--all"] --quiet | ignore
    run-command git ["-C" ($committed | into string) "commit" "-m" "bundled state"] --quiet | ignore
    let head = (run-command git ["-C" ($committed | into string) "rev-parse" "HEAD"] --quiet --capture)
    let bundle_out = ($sandbox | path join "state-bundle.tar.gz")
    make-state-bundle $committed $bundle_out ($head.stdout | str trim)
    let bundle_dest = ($sandbox | path join "bundle-state")
    let bundle_result = (import-state-source $bundle_dest $bundle_out [personal])
    assert eq $bundle_result.kind "bundle" "bundle source detected"
    assert eq $bundle_result.revision ($head.stdout | str trim) "bundle state_revision retained"
    assert (($bundle_dest | path join "config" "recovery.nuon") | path exists) "bundle state imported"
    let record = (import-record-load $bundle_dest {})
    assert eq $record.state_revision ($head.stdout | str trim) "import record preserves the bundle revision"

    # Paths containing spaces import and commit correctly (both the source and
    # the destination root).
    let spaced_src = ($sandbox | path join "spaced source")
    mkdir $spaced_src
    for entry in (ls --all $state_root) { cp --recursive $entry.name ($spaced_src | path join ($entry.name | path basename)) }
    let spaced_dest = ($sandbox | path join "spaced destination")
    let spaced = (import-state-source $spaced_dest $spaced_src [personal])
    assert eq $spaced.status "imported" "a state source with spaces imports"
    assert (($spaced_dest | path join "config" "recovery.nuon") | path exists) "a spaced destination receives the state"
    let spaced_probe = (repo-probe $spaced_dest $cfg)
    assert $spaced_probe.committed "a spaced destination is a committed repository"

    # A host that enables commit signing (without a usable key) must not block
    # recovery: the synthetic import commit is created with signing disabled.
    with-temp-dir "reseed-import-signing.XXXXXXXX" {|signing_cfg_dir|
      let signing_cfg = ($signing_cfg_dir | path join "gitconfig")
      "[commit]\n\tgpgsign = true\n[user]\n\tsigningkey = 0000000000000000000000000000000000000000\n" | save $signing_cfg
      let signed_dest = ($sandbox | path join "signed-state")
      let imported = (with-env {GIT_CONFIG_GLOBAL: ($signing_cfg | into string)} {
        import-state-source $signed_dest $src [personal]
      })
      assert eq $imported.status "imported" "an import succeeds even when the host enables commit signing"
      let head_commit = (run-command git ["-C" ($signed_dest | into string) "cat-file" "commit" "HEAD"] --quiet --capture)
      assert (not ($head_commit.stdout | str contains "gpgsig")) "the synthetic import commit is not signed"
    }
  }
}

# A minimal offline bundle for a committed state repository: reseed/bundle.nuon
# with the recorded state_revision plus the archived state snapshot.
def make-state-bundle [committed: path, output: path, revision: string] {
  let staging = (mktemp --directory)
  try {
    mkdir ($staging | path join "reseed" "state")
    run-command git ["-C" ($committed | into string) "archive" "--format=tar" "--output" ($staging | path join "state.tar") "HEAD"] --quiet | ignore
    run-command tar ["-xf" ($staging | path join "state.tar") "-C" ($staging | path join "reseed" "state")] --quiet | ignore
    rm ($staging | path join "state.tar")
    {schema: 1 platform: "test" state_revision: $revision} | to nuon --indent 2 | save --force ($staging | path join "reseed" "bundle.nuon")
    run-command tar ["-czf" ($output | into string) "-C" ($staging | into string) "reseed"] --quiet | ignore
  } finally { rm --recursive --force $staging }
}

# A bare origin and a clone at the same commit, with local identity configured.
def sync-origin [sandbox: path, name: string]: nothing -> path {
  let origin = ($sandbox | path join $"($name).git")
  run-command git ["init" "--bare" "-q" "-b" "main" ($origin | into string)] --quiet | ignore
  let seed = ($sandbox | path join $"($name)-seed")
  run-command git ["init" "-q" "-b" "main" ($seed | into string)] --quiet | ignore
  configure-git-identity $seed
  "base\n" | save ($seed | path join "seed.txt")
  run-command git ["-C" ($seed | into string) "add" "--all"] --quiet | ignore
  run-command git ["-C" ($seed | into string) "commit" "-m" "seed"] --quiet | ignore
  run-command git ["-C" ($seed | into string) "remote" "add" "origin" ($origin | into string)] --quiet | ignore
  run-command git ["-C" ($seed | into string) "push" "-u" "origin" "main"] --quiet | ignore
  $origin
}

# A fresh clone of an origin with local identity configured.
def sync-clone [sandbox: path, name: string, origin: path]: nothing -> path {
  let clone = ($sandbox | path join $name)
  run-command git ["clone" "-q" ($origin | into string) ($clone | into string)] --quiet | ignore
  configure-git-identity $clone
  $clone
}

# Advance an origin by one commit from a sibling clone.
def advance-origin [sandbox: path, name: string, origin: path, content: string, file: string = "rival.txt"] {
  let sibling = (sync-clone $sandbox $name $origin)
  $content | save ($sibling | path join $file)
  run-command git ["-C" ($sibling | into string) "add" "--all"] --quiet | ignore
  run-command git ["-C" ($sibling | into string) "commit" "-m" $"add ($file)"] --quiet | ignore
  run-command git ["-C" ($sibling | into string) "push" "origin" "main"] --quiet | ignore
}

# A bare origin whose main branch contains a valid private-state tree.
def make-state-origin [sandbox: path, name: string, state_root: path]: nothing -> path {
  let origin = ($sandbox | path join $"($name).git")
  run-command git ["init" "--bare" "-q" "-b" "main" ($origin | into string)] --quiet | ignore
  let seed = ($sandbox | path join $"($name)-seed")
  mkdir $seed
  for entry in (ls --all $state_root) { cp --recursive $entry.name ($seed | path join ($entry.name | path basename)) }
  run-command git ["-C" ($seed | into string) "init" "-q" "-b" "main"] --quiet | ignore
  configure-git-identity $seed
  run-command git ["-C" ($seed | into string) "add" "--all"] --quiet | ignore
  run-command git ["-C" ($seed | into string) "commit" "-m" "state"] --quiet | ignore
  run-command git ["-C" ($seed | into string) "remote" "add" "origin" ($origin | into string)] --quiet | ignore
  run-command git ["-C" ($seed | into string) "push" "-u" "origin" "main"] --quiet | ignore
  $origin
}

# The sync matrix: first attachment, fast-forward, ahead push, dirty commit,
# divergence, conflicts with continue/abort, empty remotes, push races, missing
# branches, detached/shallow repositories, inaccessible remotes, mismatches,
# provenance-based merging, and unknown-base snapshot preservation.
def test-repo-sync [engine_root: path, state_root: path] {
  if not (command-exists git) { return }
  let cfg = (test-git-config)
  with-temp-dir "reseed-syncmatrix.XXXXXXXX" {|sandbox|
    # First attachment: an unborn sentinel root adopts the remote.
    let origin = (sync-origin $sandbox "attach")
    let root = ($sandbox | path join "attach-root")
    run-command git ["init" "-q" "-b" "main" ($root | into string)] --quiet | ignore
    ".reseed-state\n" | save ($root | path join ".reseed-state")
    let attached = (repo-sync $root $cfg --remote-url=($origin | into string))
    assert eq $attached.status "adopted" "first attachment adopts the remote"
    assert (($root | path join "seed.txt") | path exists) "adoption copies the remote state"

    # Fast-forward when behind.
    let origin2 = (sync-origin $sandbox "ff")
    let root2 = (sync-clone $sandbox "ff-root" $origin2)
    advance-origin $sandbox "ff-rival" $origin2 "forward\n"
    # A dry run must not mutate the repository: the remote-tracking ref stays
    # at its cached value and the working tree is untouched, and it reports the
    # real phase (behind) instead of claiming synchronization.
    let cached_before = (run-command git ["-C" ($root2 | into string) "rev-parse" "refs/remotes/origin/main"] --quiet --capture)
    let dry = (repo-sync $root2 $cfg --dry-run)
    let cached_after = (run-command git ["-C" ($root2 | into string) "rev-parse" "refs/remotes/origin/main"] --quiet --capture)
    assert eq ($cached_after.stdout | str trim) ($cached_before.stdout | str trim) "sync --dry-run does not fetch or move remote-tracking refs"
    assert (not (($root2 | path join "rival.txt") | path exists)) "sync --dry-run does not change the working tree"
    assert eq $dry.status "behind" "sync --dry-run reports the real phase"
    assert (not $dry.synced) "sync --dry-run never claims synchronization for a behind repo"
    let ff = (repo-sync $root2 $cfg)
    assert eq $ff.status "synced" "behind sync fast-forwards"
    assert (($root2 | path join "rival.txt") | path exists) "fast-forward brings the remote change"

    # Ahead: reported without --push, published with it.
    let origin3 = (sync-origin $sandbox "ahead")
    let root3 = (sync-clone $sandbox "ahead-root" $origin3)
    "local commit\n" | save ($root3 | path join "local.txt")
    run-command git ["-C" ($root3 | into string) "add" "--all"] --quiet | ignore
    run-command git ["-C" ($root3 | into string) "commit" "-m" "local ahead"] --quiet | ignore
    let ahead = (repo-sync $root3 $cfg)
    assert eq $ahead.status "ahead" "ahead sync reports without pushing"
    let pushed = (repo-sync $root3 $cfg --push)
    assert eq $pushed.status "pushed" "ahead sync with --push publishes"
    let remote_has = (run-command git ["ls-remote" ($origin3 | into string) "refs/heads/main"] --quiet --capture)
    assert (($remote_has.stdout | str trim) != "") "the remote gained the pushed commit"

    # Dirty state: refused without --commit, committed with it.
    let origin4 = (sync-origin $sandbox "dirty")
    let root4 = (sync-clone $sandbox "dirty-root" $origin4)
    "uncommitted\n" | save --append ($root4 | path join "seed.txt")
    let dirty = (repo-sync $root4 $cfg)
    assert eq $dirty.status "dirty" "dirty sync refuses without --commit"
    assert ((open --raw ($root4 | path join "seed.txt")) | str contains "uncommitted") "dirty refusal leaves the changes alone"
    let committed = (repo-sync $root4 $cfg --commit --yes)
    assert eq $committed.status "ahead" "dirty sync with --commit commits and reports the new commit"
    let log = (run-command git ["-C" ($root4 | into string) "log" "-1" "--format=%s"] --quiet --capture)
    assert ($log.stdout | str contains "Sync") "dirty sync commits with a sync message"
    let committed_push = (repo-sync $root4 $cfg --push)
    assert eq $committed_push.status "pushed" "the committed dirty state can be pushed"

    # Divergence merges both histories.
    let origin5 = (sync-origin $sandbox "diverge")
    let root5 = (sync-clone $sandbox "diverge-root" $origin5)
    "local file\n" | save ($root5 | path join "local.txt")
    run-command git ["-C" ($root5 | into string) "add" "--all"] --quiet | ignore
    run-command git ["-C" ($root5 | into string) "commit" "-m" "local work"] --quiet | ignore
    advance-origin $sandbox "diverge-rival" $origin5 "remote file\n"
    let merged = (repo-sync $root5 $cfg)
    assert eq $merged.status "merged" "divergence merges both histories"
    assert (($root5 | path join "local.txt") | path exists) "merge preserves local work"
    assert (($root5 | path join "rival.txt") | path exists) "merge preserves remote work"

    # Conflicts: sync --continue and sync --abort.
    let origin6 = (sync-origin $sandbox "conflict")
    let root6 = (sync-clone $sandbox "conflict-root" $origin6)
    "local line\n" | save --force ($root6 | path join "seed.txt")
    run-command git ["-C" ($root6 | into string) "add" "--all"] --quiet | ignore
    run-command git ["-C" ($root6 | into string) "commit" "-m" "local seed"] --quiet | ignore
    let rival6 = (sync-clone $sandbox "conflict-rival" $origin6)
    "remote line\n" | save --force ($rival6 | path join "seed.txt")
    run-command git ["-C" ($rival6 | into string) "add" "--all"] --quiet | ignore
    run-command git ["-C" ($rival6 | into string) "commit" "-m" "remote seed"] --quiet | ignore
    run-command git ["-C" ($rival6 | into string) "push" "origin" "main"] --quiet | ignore
    let conflicted = (repo-sync $root6 $cfg)
    assert eq $conflicted.status "conflicts" "divergence with overlapping edits conflicts"
    assert ((merge-intent-load $root6 $cfg) != null) "merge intent is persisted outside the repository"

    # Staging an unresolved conflict must not let sync --continue commit the
    # markers: the staged diff is checked too.
    run-command git ["-C" ($root6 | into string) "add" "--all"] --quiet | ignore
    let staged_markers = (repo-merge-continue $root6 $cfg)
    assert eq $staged_markers.status "conflicts" "sync --continue rejects staged conflict markers"
    assert (not (($staged_markers.synced))) "staged markers are never committed"

    let aborted = (repo-merge-abort $root6 $cfg)
    assert eq $aborted.status "aborted" "sync --abort discards the merge"
    assert ((merge-intent-load $root6 $cfg) == null) "abort clears the merge intent"
    let after_abort = (run-command git ["-C" ($root6 | into string) "log" "-1" "--format=%s"] --quiet --capture)
    assert eq ($after_abort.stdout | str trim) "local seed" "abort restores the pre-merge state"

    let conflicted2 = (repo-sync $root6 $cfg)
    assert eq $conflicted2.status "conflicts" "the merge is retried after abort"
    "both lines\n" | save --force ($root6 | path join "seed.txt")
    run-command git ["-C" ($root6 | into string) "add" "seed.txt"] --quiet | ignore
    let completed = (repo-merge-continue $root6 $cfg)
    assert eq $completed.status "completed" "sync --continue completes the resolved merge"
    assert ((merge-intent-load $root6 $cfg) == null) "continue clears the merge intent"

    # Empty remote: report, then publish.
    let empty = ($sandbox | path join "empty.git")
    run-command git ["init" "--bare" "-q" "-b" "main" ($empty | into string)] --quiet | ignore
    let empty_root = ($sandbox | path join "empty-root")
    run-command git ["init" "-q" "-b" "main" ($empty_root | into string)] --quiet | ignore
    configure-git-identity $empty_root
    ".reseed-state\n" | save ($empty_root | path join ".reseed-state")
    "snapshot\n" | save ($empty_root | path join "state.txt")
    run-command git ["-C" ($empty_root | into string) "add" "--all"] --quiet | ignore
    run-command git ["-C" ($empty_root | into string) "commit" "-m" "local snapshot"] --quiet | ignore
    let empty_report = (repo-sync $empty_root $cfg --remote-url=($empty | into string))
    assert eq $empty_report.status "empty-remote" "an empty remote is reported without --push"
    let empty_push = (repo-sync $empty_root $cfg --remote-url=($empty | into string) --push)
    assert eq $empty_push.status "pushed" "an empty remote accepts the first push"
    let empty_has = (run-command git ["ls-remote" ($empty | into string) "refs/heads/main"] --quiet --capture)
    assert (($empty_has.stdout | str trim) != "") "the empty remote gained the branch"

    # Missing branch: refuse to guess.
    let dev_origin = ($sandbox | path join "dev.git")
    run-command git ["init" "--bare" "-q" ($dev_origin | into string)] --quiet | ignore
    let dev_seed = ($sandbox | path join "dev-seed")
    run-command git ["init" "-q" "-b" "dev" ($dev_seed | into string)] --quiet | ignore
    configure-git-identity $dev_seed
    "dev\n" | save ($dev_seed | path join "dev.txt")
    run-command git ["-C" ($dev_seed | into string) "add" "--all"] --quiet | ignore
    run-command git ["-C" ($dev_seed | into string) "commit" "-m" "dev"] --quiet | ignore
    run-command git ["-C" ($dev_seed | into string) "remote" "add" "origin" ($dev_origin | into string)] --quiet | ignore
    run-command git ["-C" ($dev_seed | into string) "push" "-u" "origin" "dev"] --quiet | ignore
    let dev_root = ($sandbox | path join "dev-root")
    run-command git ["init" "-q" "-b" "main" ($dev_root | into string)] --quiet | ignore
    configure-git-identity $dev_root
    ".reseed-state\n" | save ($dev_root | path join ".reseed-state")
    let missing = (repo-sync $dev_root $cfg --remote-url=($dev_origin | into string))
    assert eq $missing.status "missing-branch" "a remote without the configured branch is refused"

    # Push race: a push loses to a moved remote and the retry fast-forwards.
    let origin7 = (sync-origin $sandbox "race")
    let root7 = (sync-clone $sandbox "race-root" $origin7)
    advance-origin $sandbox "race-rival" $origin7 "moved\n"
    let race = (repo-push $root7 $cfg)
    assert $race.ok "a lost push race retries once and fast-forwards"
    assert (($root7 | path join "rival.txt") | path exists) "the race retry fetched the moved remote"

    # Detached HEAD reattaches to the configured branch, and recovered commits
    # made on the detached HEAD are preserved into the branch.
    let origin8 = (sync-origin $sandbox "detached")
    let root8 = (sync-clone $sandbox "detached-root" $origin8)
    let base_sha = (run-command git ["-C" ($root8 | into string) "rev-parse" "HEAD"] --quiet --capture)
    run-command git ["-C" ($root8 | into string) "checkout" "-q" ($base_sha.stdout | str trim)] --quiet | ignore
    "recovered on detached\n" | save ($root8 | path join "detached-work.txt")
    run-command git ["-C" ($root8 | into string) "add" "--all"] --quiet | ignore
    run-command git ["-C" ($root8 | into string) "commit" "-m" "recovered detached commit"] --quiet | ignore
    let reattached = (repo-sync $root8 $cfg)
    assert eq $reattached.status "ahead" "a detached HEAD reattaches on sync and keeps its recovered commits ahead"
    let branch = (run-command git ["-C" ($root8 | into string) "branch" "--show-current"] --quiet --capture)
    assert eq ($branch.stdout | str trim) "main" "detached sync lands on the configured branch"
    assert (($root8 | path join "detached-work.txt") | path exists) "detached recovered commits are preserved"
    let detached_log = (run-command git ["-C" ($root8 | into string) "log" "--oneline"] --quiet --capture)
    assert (($detached_log.stdout | str contains "recovered detached commit")) "the recovered detached commit survives reattachment"
    let detached_push = (repo-sync $root8 $cfg --push)
    assert eq $detached_push.status "pushed" "the preserved detached commits can be pushed"
    let recovery_refs = (run-command git ["-C" ($root8 | into string) "for-each-ref" "refs/reseed/recovered"] --allow-failure --quiet --capture)
    assert (($recovery_refs.stdout | str trim | is-empty)) "the detached recovery ref is cleaned up after reattachment"

    # Shallow clones deepen and fast-forward. A file:// URL honors --depth so
    # the fixture is genuinely shallow.
    let origin9 = (sync-origin $sandbox "shallow")
    let root9 = ($sandbox | path join "shallow-root")
    let origin9_url = ($"file://($origin9 | into string)" | str replace --all "\\" "/")
    run-command git ["clone" "-q" "--depth" "1" $origin9_url ($root9 | into string)] --quiet | ignore
    configure-git-identity $root9
    let shallow_probe = (repo-probe $root9 $cfg)
    assert $shallow_probe.shallow "the fixture clone is genuinely shallow"
    advance-origin $sandbox "shallow-rival" $origin9 "deeper\n"
    let deepened = (repo-sync $root9 $cfg)
    assert eq $deepened.status "synced" "a shallow clone deepens and fast-forwards on sync"
    assert (($root9 | path join "rival.txt") | path exists) "the deepened clone has the remote change"
    assert (not (repo-probe $root9 $cfg).shallow) "a sync resolves the shallow state entirely"

    # An up-to-date shallow clone must not stay shallow forever: sync resolves
    # the shallow state even when there is nothing to fetch.
    let origin9b = (sync-origin $sandbox "shallow-tip")
    let root9b = ($sandbox | path join "shallow-tip-root")
    let origin9b_url = ($"file://($origin9b | into string)" | str replace --all "\\" "/")
    run-command git ["clone" "-q" "--depth" "1" $origin9b_url ($root9b | into string)] --quiet | ignore
    configure-git-identity $root9b
    let tip_sync = (repo-sync $root9b $cfg)
    assert $tip_sync.synced "an up-to-date shallow clone syncs cleanly"
    assert (not (repo-probe $root9b $cfg).shallow) "an up-to-date shallow clone is resolved on sync"

    # Read-only probing must compare against the actual remote tip from
    # ls-remote, not the stale cache: an advanced remote is reported as behind,
    # never as synchronized.
    let originS = (sync-origin $sandbox "stale")
    let rootS = (sync-clone $sandbox "stale-root" $originS)
    advance-origin $sandbox "stale-rival" $originS "newer\n"
    let stale_probe = (repo-probe $rootS $cfg --read-only)
    assert eq $stale_probe.phase "behind" "read-only status reports an advanced remote as behind"
    assert $stale_probe.remote_ahead "read-only status flags that the remote has advanced"
    let stale_status = (workflow-status-facts $engine_root $rootS $cfg --offline=false)
    assert eq $stale_status.phase "behind" "status facts never claim synchronization against a stale tip"

    # A leftover recovery ref from a sync that crashed between switching to the
    # branch and merging is consumed on the next sync.
    let originL = (sync-origin $sandbox "leftover")
    let rootL = (sync-clone $sandbox "leftover-root" $originL)
    let base_sha = (run-command git ["-C" ($rootL | into string) "rev-parse" "HEAD"] --quiet --capture)
    run-command git ["-C" ($rootL | into string) "checkout" "-q" ($base_sha.stdout | str trim)] --quiet | ignore
    "recovered on detached\n" | save ($rootL | path join "recovered.txt")
    run-command git ["-C" ($rootL | into string) "add" "--all"] --quiet | ignore
    run-command git ["-C" ($rootL | into string) "commit" "-m" "detached recovery"] --quiet | ignore
    let recovered_sha = (run-command git ["-C" ($rootL | into string) "rev-parse" "HEAD"] --quiet --capture)
    run-command git ["-C" ($rootL | into string) "update-ref" "refs/reseed/recovered/main" ($recovered_sha.stdout | str trim)] --quiet | ignore
    run-command git ["-C" ($rootL | into string) "switch" "-q" "main"] --quiet | ignore
    let leftover_sync = (repo-sync $rootL $cfg)
    assert ($leftover_sync.synced or $leftover_sync.status == "ahead") "a sync consumes a leftover detached recovery ref"
    assert (($rootL | path join "recovered.txt") | path exists) "leftover recovered commits are merged into the branch"
    let leftover_refs = (run-command git ["-C" ($rootL | into string) "for-each-ref" "refs/reseed/recovered"] --allow-failure --quiet --capture)
    assert (($leftover_refs.stdout | str trim | is-empty)) "the consumed recovery ref is removed"

    # Inaccessible remotes are reported.
    let origin10 = (sync-origin $sandbox "unreachable")
    let root10 = (sync-clone $sandbox "unreachable-root" $origin10)
    run-command git ["-C" ($root10 | into string) "remote" "set-url" "origin" ($sandbox | path join "missing.git")] --quiet | ignore
    let unreachable = (repo-sync $root10 $cfg)
    assert eq $unreachable.status "inaccessible" "an unreachable remote is reported"

    # Origin/config mismatches are refused.
    let origin11 = (sync-origin $sandbox "origin")
    let root11 = (sync-clone $sandbox "origin-root" $origin11)
    let mismatched = (repo-sync $root11 $cfg --remote-url=($sandbox | path join "elsewhere.git"))
    assert eq $mismatched.status "mismatched" "a requested URL differing from origin is refused"

    # Provenance-based merging: a bundle snapshot rebases onto its recorded
    # state_revision, so both the recovered changes and the remote history
    # survive.
    let origin12 = (make-state-origin $sandbox "provenance" $state_root)
    let bundled = (sync-clone $sandbox "provenance-bundled" $origin12)
    run-command git ["-C" ($bundled | into string) "remote" "remove" "origin"] --quiet | ignore
    "recovered change\n" | save ($bundled | path join "recovered.txt")
    run-command git ["-C" ($bundled | into string) "add" "--all"] --quiet | ignore
    run-command git ["-C" ($bundled | into string) "commit" "-m" "recovered change"] --quiet | ignore
    let bundled_head = (run-command git ["-C" ($bundled | into string) "rev-parse" "HEAD"] --quiet --capture)
    let bundle_out = ($sandbox | path join "provenance-bundle.tar.gz")
    make-state-bundle $bundled $bundle_out ($bundled_head.stdout | str trim)
    let prov_root = ($sandbox | path join "provenance-root")
    import-state-source $prov_root $bundle_out [personal] | ignore
    # A commit made after import must not disable provenance-based merging.
    "post-import change\n" | save ($prov_root | path join "post-import.txt")
    run-command git ["-C" ($prov_root | into string) "add" "--all"] --quiet | ignore
    run-command git ["-C" ($prov_root | into string) "commit" "-m" "post-import change"] --quiet | ignore
    advance-origin $sandbox "provenance-rival" $origin12 "remote-only\n"
    let prov_merge = (repo-sync $prov_root $cfg --remote-url=($origin12 | into string) --yes)
    assert eq $prov_merge.status "merged" "provenance-based merging preserves both histories"
    assert (($prov_root | path join "rival.txt") | path exists) "remote-only changes survive the provenance merge"
    assert (($prov_root | path join "recovered.txt") | path exists) "recovered snapshot changes survive the provenance merge"
    assert (($prov_root | path join "post-import.txt") | path exists) "post-import commits survive the provenance merge"
    let prov_parents = (run-command git ["-C" ($prov_root | into string) "log" "-1" "--format=%P"] --quiet --capture)
    assert (($prov_parents.stdout | str trim | split row " " | length) == 2) "the provenance merge is a real merge commit"

    # Unknown-base snapshot preservation: a raw snapshot with no provenance
    # merges only after the complete recovered difference is exposed.
    let origin13 = (make-state-origin $sandbox "unknownbase" $state_root)
    let raw_src = ($sandbox | path join "raw-source")
    mkdir $raw_src
    for entry in (ls --all $state_root) { cp --recursive $entry.name ($raw_src | path join ($entry.name | path basename)) }
    "recovered file\n" | save ($raw_src | path join "recovered.txt")
    let raw_root = ($sandbox | path join "raw-root")
    import-state-source $raw_root $raw_src [personal] | ignore
    advance-origin $sandbox "unknownbase-rival" $origin13 "remote-only\n"
    let unknown = (repo-sync $raw_root $cfg --remote-url=($origin13 | into string) --yes)
    assert eq $unknown.status "merged" "an unknown-base snapshot merges after review"
    assert (($raw_root | path join "recovered.txt") | path exists) "the recovered snapshot survives the unknown-base merge"
    assert (($raw_root | path join "rival.txt") | path exists) "the remote baseline survives the unknown-base merge"
  }
}

# End-to-end local-remote scenario: a downloaded snapshot imports into the
# local root, recovery changes and remote-only changes both survive, a sync
# commit/push synchronizes the remote, and the supplied source stays
# byte-for-byte unchanged.
def test-e2e-local-remote [state_root: path] {
  if not (command-exists git) { return }
  let cfg = (test-git-config)
  with-temp-dir "reseed-e2e.XXXXXXXX" {|sandbox|
    let origin = (make-state-origin $sandbox "remote" $state_root)
    let bundled = (sync-clone $sandbox "bundled" $origin)
    run-command git ["-C" ($bundled | into string) "remote" "remove" "origin"] --quiet | ignore
    let bundled_head = (run-command git ["-C" ($bundled | into string) "rev-parse" "HEAD"] --quiet --capture)
    let source = ($sandbox | path join "downloaded-state.tar.gz")
    make-state-bundle $bundled $source ($bundled_head.stdout | str trim)

    # Hash every file of the supplied source before anything touches it.
    let before = (run-command tar ["-tvf" ($source | into string)] --quiet --capture).stdout

    let local = ($sandbox | path join ".local")
    let imported = (import-state-source $local $source [personal])
    assert eq $imported.status "imported" "the downloaded snapshot imports into .local"

    # A recovery change lands only in the local state root.
    "recovered note\n" | save ($local | path join "recovered.txt")

    # The remote gains a remote-only change meanwhile.
    advance-origin $sandbox "e2e-rival" $origin "remote-only\n"

    # Sync commits the recovery change, merges the remote-only change, and
    # pushes: both survive on the local side and the remote catches up.
    let synced = (repo-sync $local $cfg --remote-url=($origin | into string) --commit --push --yes)
    assert eq $synced.status "pushed" "e2e sync commits, merges, and pushes"
    assert (($local | path join "recovered.txt") | path exists) "the recovery change survives"
    assert (($local | path join "rival.txt") | path exists) "the remote-only change survives"
    let remote_local = (sync-clone $sandbox "verify" $origin)
    assert (($remote_local | path join "recovered.txt") | path exists) "the pushed recovery change reached the remote"
    assert (($remote_local | path join "rival.txt") | path exists) "the remote keeps its own change"

    # The supplied source remains byte-for-byte unchanged.
    let after = (run-command tar ["-tvf" ($source | into string)] --quiet --capture).stdout
    assert eq $after $before "the supplied state source remains byte-for-byte unchanged"
  }
}

def main [] {
  let engine_root = ($env.FILE_PWD | path dirname)
  let state_root = ($engine_root | path join "templates" "state")

  # Isolate the temporary Git repositories from the host's global signing
  # configuration (GIT_CONFIG_GLOBAL and system config), so the behavior tests
  # do not fail on a machine that enables GPG commit signing globally.
  with-temp-dir "reseed-gitconfig.XXXXXXXX" {|sandbox|
    let global_cfg = ($sandbox | path join "empty-gitconfig")
    "" | save $global_cfg
    with-env {GIT_CONFIG_GLOBAL: ($global_cfg | into string) GIT_CONFIG_NOSYSTEM: "1"} {
      # Fast, mostly CPU-only tests run first (sequentially).
      test-config-layer $state_root
      test-manager-entries $engine_root $state_root
      test-bootstrap-contract
      test-bootstrap-updates
      test-cargo-binstall $engine_root $state_root
      test-winget-manifests $engine_root $state_root
      test-brewfile-manifests $engine_root $state_root
      test-homebrew-env $state_root
      test-homebrew-shell-snippets $state_root
      test-workflow-plan $state_root
      test-tooling-observations $engine_root $state_root
      test-mise-commands $state_root
      test-shell-generation $engine_root $state_root
      test-mise-backends $engine_root $state_root
      test-spec-parsing
      test-manifest-validation $engine_root $state_root
      test-inventory-parsing
      test-missing-packages
      test-mise-config-validation $state_root
      test-checkpoints $engine_root $state_root
      test-sync-engine-files $engine_root $state_root
      test-shell-generator-preflight $engine_root $state_root
      test-recommendations $engine_root
      test-status-facts-robust
      test-cli-robustness $engine_root

      # The repository-heavy tests are independent (each builds its own
      # disposable repositories), so they run concurrently.
      let heavy = [
        {|| test-secret-guard $engine_root }
        {|| test-git-sync }
        {|| test-init-adopt $engine_root }
        {|| test-init-reseeds-incomplete-seed $engine_root }
        {|| test-import $engine_root $state_root }
        {|| test-repo-sync $engine_root $state_root }
        {|| test-git-url-attachment $state_root }
        {|| test-e2e-local-remote $state_root }
      ]
      $heavy | par-each --threads 3 {|run| do $run } | ignore
    }
  }

  print "All Reseed tests passed"
}
