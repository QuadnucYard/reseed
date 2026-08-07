use std assert
use ./helpers.nu *
use ../lib/config.nu [config-fingerprint deep-merge load-config parse-profiles validate-config]
use ../lib/prelude.nu *
use ../lib/workflow.nu [workflow-plan workflow-verification-tools]
use ../integrations/bootstrap.nu [bootstrap-brew-items bootstrap-outdated bootstrap-tools bootstrap-winget-ids parse-brew-outdated parse-winget-upgrade-table]
use ../integrations/homebrew.nu [brewfile-items brewfile-summary homebrew-env homebrew-mirror-label homebrew-persist-env homebrew-shell-snippets native-brewfile-items parse-outdated-names]
use ../integrations/managers/cargo_binstall.nu [cargo-binstall-packages]
use ../integrations/mise.nu [mise-install-plan mise-reconcile]
use ../integrations/managers/node/node_manager.nu [node-manager-entries node-manager-install-args node-manager-missing-packages node-manager-update-args node-package-record node-spec-parse node-yarn-major-version parse-bun-inventory parse-node-dependency-inventory parse-yarn-inventory]
use ../integrations/managers/node/pnpm.nu [parse-pnpm-inventory pnpm-missing-packages pnpm-package-record pnpm-packages]
use ../integrations/tooling.nu [tooling-observe]
use ../integrations/managers/uv.nu [parse-uv-inventory uv-entries uv-missing-packages uv-package-record uv-packages uv-spec-parse]
use ../integrations/winget.nu [native-winget-manifest-ids winget-manifest-ids]

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
  let config = (load-config $state_root [personal])
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
  assert ((validate-config $state_root $cargo_config) | is-empty) "cargo-binstall config validates"
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
  let all_lines = ($snippets | get lines | flatten)
  assert ($all_lines | any {|line| $line == "$env.HOMEBREW_API_DOMAIN = \"https://mirrors.ustc.edu.cn/homebrew-bottles/api\"" }) "Nushell snippet exports the environment"
  assert ($all_lines | any {|line| $line == "set -gx HOMEBREW_BOTTLE_DOMAIN 'https://mirrors.ustc.edu.cn/homebrew-bottles'" }) "Fish snippet exports the environment"
  assert ($all_lines | any {|line| $line == "export HOMEBREW_BOTTLE_DOMAIN='https://mirrors.ustc.edu.cn/homebrew-bottles'" }) "POSIX snippet exports the environment"
  assert ($all_lines | any {|line| $line == "$env:HOMEBREW_API_DOMAIN = 'https://mirrors.ustc.edu.cn/homebrew-bottles/api'" }) "PowerShell snippet exports the environment"
  assert ($all_lines | any {|line| $line == "set -gx HOMEBREW_TOKEN 'a''b'" }) "Fish snippet escapes single quotes"
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
  engine_root: path # Engine root for the disposable test state.
  state_root: path # Private state template root.
] {
  let config = (load-config $state_root [personal])
  let dry_state = ($engine_root | path join "tests" $".reseed-tooling-test-(random uuid)")
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

# Mise command construction and the shared managed-tool environment, plus
# the generated shell adapter content.
def test-mise-commands [
  state_root: path # Private state template root.
] {
  assert eq (mise-exec-args ($state_root | path join "mise.toml") "pnpm" ["--version"]) ["-C" ($state_root | into string) "exec" "--" "pnpm" "--version"] "mise exec command construction"
  assert eq (mise-exec-args ($state_root | path join "mise.work.toml") "uv" ["--version"]) ["-C" ($state_root | into string) "-E" "work" "exec" "--" "uv" "--version"] "mise environment command construction"
  assert eq ((managed-tool-environment).PNPM_HOME) (managed-bin-dir | into string) "PNPM_HOME uses managed bin directory"
  assert eq ((managed-tool-environment).UV_TOOL_BIN_DIR) (managed-bin-dir | into string) "UV_TOOL_BIN_DIR uses managed bin directory"
  assert eq ((managed-tool-environment).YARN_PREFIX) (managed-bin-dir | path dirname | into string) "YARN_PREFIX uses managed root"
  assert eq ((managed-tool-environment).BUN_INSTALL) (managed-bin-dir | path dirname | into string) "BUN_INSTALL uses managed root"
  let shell_script = (open --raw ($state_root | path join "scripts" "configure-shells.nu"))
  assert ($shell_script | str contains "PNPM_HOME") "shell generation includes PNPM_HOME"
  assert ($shell_script | str contains "UV_TOOL_BIN_DIR") "shell generation includes UV_TOOL_BIN_DIR"
  assert ($shell_script | str contains "YARN_PREFIX") "shell generation includes YARN_PREFIX"
  assert ($shell_script | str contains "BUN_INSTALL") "shell generation includes BUN_INSTALL"
  assert ($shell_script | str contains "PowerShell profile") "shell generation includes PowerShell adapter"
  assert ($shell_script | str contains "POSIX profile") "shell generation includes POSIX adapter"
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
  assert ((mise-manager-config $state_root $config) | path exists) "manager config resolves to an existing file"

  let invalid_mise = ($config | upsert software.mise.configs [tools.custom.toml])
  let invalid_issues = (validate-config $state_root $invalid_mise)
  assert ($invalid_issues | any {|issue| $issue.area == mise and ($issue.message | str contains "Unsupported config name") }) "mise config names are validated"
  let missing_task = ($config | upsert software.mise.task_files [scripts/missing.nu])
  assert ((validate-config $state_root $missing_task) | any {|issue| $issue.area == mise and ($issue.message | str contains "Missing mise task file") }) "mise task files are validated"
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

def main [] {
  let engine_root = ($env.FILE_PWD | path dirname)
  let state_root = ($engine_root | path join "templates" "state")

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
  test-mise-backends $engine_root $state_root
  test-spec-parsing
  test-manifest-validation $engine_root $state_root
  test-inventory-parsing
  test-missing-packages
  test-mise-config-validation $state_root
  test-checkpoints $engine_root $state_root

  print "All Reseed tests passed"
}
