use ../lib/config.nu [config-fingerprint deep-merge load-config parse-profiles validate-config]
use ../lib/prelude.nu *
use ../lib/workflow.nu [workflow-plan workflow-verification-tools]
use ../integrations/bootstrap.nu [bootstrap-brew-items bootstrap-tools bootstrap-winget-ids]
use ../integrations/homebrew.nu [brewfile-items native-brewfile-items]
use ../integrations/managers/cargo_binstall.nu [cargo-binstall-packages]
use ../integrations/mise.nu [mise-install-plan mise-reconcile]
use ../integrations/managers/node/node_manager.nu [node-manager-entries node-manager-install-args node-manager-missing-packages node-manager-update-args node-package-record node-spec-parse node-yarn-major-version parse-bun-inventory parse-node-dependency-inventory parse-yarn-inventory]
use ../integrations/managers/node/pnpm.nu [parse-pnpm-inventory pnpm-missing-packages pnpm-package-record pnpm-packages]
use ../integrations/tooling.nu [tooling-observe]
use ../integrations/managers/uv.nu [parse-uv-inventory uv-entries uv-missing-packages uv-package-record uv-packages uv-spec-parse]
use ../integrations/winget.nu [native-winget-manifest-ids winget-manifest-ids]

# Fail the test run unless the actual value equals the expected one.
def assert-equal [
  actual: any # Value produced by the code under test.
  expected: any # Value the test expects.
  label: string # Description shown when the assertion fails.
] {
  if $actual != $expected {
    error make {msg: $"($label): expected ($expected | to nuon), got ($actual | to nuon)"}
  }
}

# Fail the test run unless the actual value is true.
def assert-true [
  actual: bool # Value produced by the code under test.
  label: string # Description shown when the assertion fails.
] {
  if not $actual { error make {msg: $"($label): expected true"} }
}

# Configuration loading: deep merge, profile parsing, command display and
# URL redaction, missing-command capture, and template validation.
def test-config-layer [
  state_root: path # Private state template root.
] {
  let merged = (deep-merge
    {software: {mise: {enabled: true configs: [base]}} labels: [base]}
    {software: {mise: {configs: [work]}} labels: [work]})
  assert-equal $merged.software.mise.enabled true "deep merge preserves nested values"
  assert-equal $merged.software.mise.configs [work] "deep merge replaces arrays"
  assert-equal $merged.labels [work] "top-level arrays replace"

  assert-equal (parse-profiles " personal, work ") [personal work] "profile parsing"
  assert-equal (show-command "a tool" ["plain" "two words"]) '"a tool" plain "two words"' "command rendering"
  assert-equal (scrub-url "https://user:token@example.com/repo") "https://***@example.com/repo" "URL credentials are redacted"
  assert-equal (scrub-url "https://example.com/repo") "https://example.com/repo" "URLs without credentials are unchanged"
  assert-equal (scrub-url "ssh://git@example.com/repo") "ssh://***@example.com/repo" "SSH URLs with userinfo are redacted"
  assert-equal (show-command git ["clone" "https://user:token@example.com/repo"]) "git clone https://***@example.com/repo" "command display redacts credentials"
  let missing_command = (run-command "reseed-no-such-command" [] --allow-failure --quiet)
  assert-equal $missing_command.exit_code 127 "missing executables are captured under allow-failure"
  let config = (load-config $state_root [personal])
  assert-equal $config.active_profiles [personal] "active profile recording"
  assert-true ((validate-config $state_root $config) | is-empty) "state template validates"
}

# Desired-state reading: uv and Node manager manifest entries and their
# merging rules.
def test-manager-entries [
  engine_root: path # Engine root for fixture paths.
  state_root: path # Private state template root.
] {
  let config = (load-config $state_root [personal])
  assert-equal (uv-packages $state_root $config) [ruff] "uv manifest packages"
  assert-equal (pnpm-packages $state_root $config) ["@biomejs/biome"] "pnpm manifest packages"
  assert-equal (uv-entries $state_root $config) [{spec: ruff name: ruff version: null commands: [ruff]}] "uv command declaration"
  assert-equal (node-manager-entries $state_root $config pnpm) [{spec: "@biomejs/biome" name: "@biomejs/biome" version: null commands: [biome]}] "pnpm command declaration"
  assert-equal (node-manager-entries $state_root $config yarn) [] "yarn sibling manifest"
  assert-equal (node-manager-entries $state_root $config bun) [] "bun sibling manifest"
  let commands_config = ($config | upsert software.mise.pnpm.manifests [tests/fixtures/pnpm-commands-a.nuon tests/fixtures/pnpm-commands-b.nuon])
  assert-equal (node-manager-entries $engine_root $commands_config pnpm) [{spec: "@biomejs/biome" name: "@biomejs/biome" version: null commands: [biome biome-fmt]}] "duplicate node manager specs merge commands"
  let all_node_managers = ($config
    | upsert software.mise.yarn {enabled: true manifests: [packages/node/yarn/global.nuon] update: true}
    | upsert software.mise.bun {enabled: true manifests: [packages/node/bun/global.nuon] update: true})
  assert-equal (mise-reconcile $state_root $all_node_managers --dry-run | get tool) [mise uv pnpm yarn bun] "Node managers share the mise lifecycle"
  let mise_tools = (open ($state_root | path join "mise.toml")).tools
  for key in [node "aqua:pnpm/pnpm" "aqua:astral-sh/uv"] {
    assert-true ($key in ($mise_tools | columns)) $"mise owns ($key)"
  }
  assert-equal $config.software.mise.manager_config "mise.toml" "mise manager config"
}

# The bootstrap contract: the tools the engine owns and the identifiers
# native manifests must exclude.
def test-bootstrap-contract [] {
  assert-equal (bootstrap-tools | get command) [git chezmoi nu mise] "bootstrap contract"
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
  assert-true ((validate-config $state_root $cargo_config) | is-empty) "cargo-binstall config validates"
  let cargo_fixture_config = ($config | upsert software.mise.cargo_binstall {
    enabled: true
    manifests: [tests/fixtures/cargo-binstall.nuon]
    update: true
  })
  assert-equal (cargo-binstall-packages $engine_root $cargo_fixture_config) [alpha beta] "cargo-binstall packages are unique and sorted"
}

# WinGet manifest extraction and bootstrap-tool filtering.
def test-winget-manifests [
  engine_root: path # Engine root for fixture paths.
  state_root: path # Private state template root.
] {
  let bootstrap_ids = (bootstrap-winget-ids)
  let winget_ids = (winget-manifest-ids ($state_root | path join "packages" "windows" "winget.json"))
  assert-equal ($winget_ids | length) 0 "empty example WinGet manifest extraction"
  assert-true (not ($winget_ids | any {|id| $id in $bootstrap_ids })) "WinGet excludes bootstrap tools"
  assert-equal (winget-manifest-ids ($engine_root | path join "tests" "fixtures" "winget-empty.json")) [] "empty WinGet export"
  assert-equal (native-winget-manifest-ids ($engine_root | path join "tests" "fixtures" "winget-bootstrap.json")) [example.tool] "WinGet filters bootstrap packages"
}

# Brewfile extraction and bootstrap-tool filtering.
def test-brewfile-manifests [
  engine_root: path # Engine root for fixture paths.
  state_root: path # Private state template root.
] {
  let bootstrap_items = (bootstrap-brew-items)
  let brew_items = (brewfile-items ($state_root | path join "packages" "macos" "Brewfile"))
  assert-equal ($brew_items | length) 1 "curated Brewfile item extraction"
  assert-true ('brew "fish"' in $brew_items) "Brewfile contains fish"
  assert-true (not ($brew_items | any {|item| $item in $bootstrap_items })) "Brewfile excludes bootstrap tools"
  assert-equal (brewfile-items ($engine_root | path join "tests" "fixtures" "Brewfile.comments")) [
    'brew "git"'
    'cask "visual-studio-code"'
    'tap "homebrew/cask"'
  ] "Brewfile comments and blank lines"
  assert-equal (native-brewfile-items ($engine_root | path join "tests" "fixtures" "Brewfile.bootstrap")) ['brew "fish"'] "Brewfile filters bootstrap packages"
}

# The ordered restore plan and its verification scope.
def test-workflow-plan [
  state_root: path # Private state template root.
] {
  let config = (load-config $state_root [personal])
  let plan = (workflow-plan $state_root $config)
  assert-equal ($plan.stage) [system-packages portable-tools configuration snapshots verification] "restore dependency order"
  assert-equal ($plan.order) [1 2 3 4 5] "restore ordering is stable"
  let offline_plan = (workflow-plan $state_root $config --skip-software)
  assert-equal ($offline_plan.enabled | first 2) [false false] "configuration-only restore skips software"
  assert-equal (workflow-verification-tools) [bootstrap winget homebrew mise chezmoi kopia] "full verification scope"
  assert-equal (workflow-verification-tools --skip-software) [bootstrap chezmoi kopia] "offline verification scope"
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

  let unknown = (tooling-observe $state_root ($tooling_config | upsert observations.tool_managers [future-manager]) --dry-run | first)
  assert-equal $unknown.ok false "unknown observation manager is reported"
  assert-true ($unknown.migration | str contains "add an integration") "unknown observation manager reserves an extension point"
}

# Mise command construction and the shared managed-tool environment, plus
# the generated shell adapter content.
def test-mise-commands [
  state_root: path # Private state template root.
] {
  assert-equal (mise-exec-args ($state_root | path join "mise.toml") "pnpm" ["--version"]) ["-C" ($state_root | into string) "exec" "--" "pnpm" "--version"] "mise exec command construction"
  assert-equal (mise-exec-args ($state_root | path join "mise.work.toml") "uv" ["--version"]) ["-C" ($state_root | into string) "-E" "work" "exec" "--" "uv" "--version"] "mise environment command construction"
  assert-equal ((managed-tool-environment).PNPM_HOME) (managed-bin-dir | into string) "PNPM_HOME uses managed bin directory"
  assert-equal ((managed-tool-environment).UV_TOOL_BIN_DIR) (managed-bin-dir | into string) "UV_TOOL_BIN_DIR uses managed bin directory"
  assert-equal ((managed-tool-environment).YARN_PREFIX) (managed-bin-dir | path dirname | into string) "YARN_PREFIX uses managed root"
  assert-equal ((managed-tool-environment).BUN_INSTALL) (managed-bin-dir | path dirname | into string) "BUN_INSTALL uses managed root"
  let shell_script = (open --raw ($state_root | path join "scripts" "configure-shells.nu"))
  assert-true ($shell_script | str contains "PNPM_HOME") "shell generation includes PNPM_HOME"
  assert-true ($shell_script | str contains "UV_TOOL_BIN_DIR") "shell generation includes UV_TOOL_BIN_DIR"
  assert-true ($shell_script | str contains "YARN_PREFIX") "shell generation includes YARN_PREFIX"
  assert-true ($shell_script | str contains "BUN_INSTALL") "shell generation includes BUN_INSTALL"
  assert-true ($shell_script | str contains "PowerShell profile") "shell generation includes PowerShell adapter"
  assert-true ($shell_script | str contains "POSIX profile") "shell generation includes POSIX adapter"
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
  assert-equal (mise-missing-backend-dependencies $backend_path | get tool) [node rust python] "mise backend dependency validation"
  assert-equal (mise-backend-dependencies $complete_backend_path | get tool) [node rust python] "mise dependency ordering"
  let missing_dependency_config = ($config
    | upsert software.mise.configs [tests/fixtures/mise.backends.toml]
    | upsert software.mise.manager_config tests/fixtures/mise.backends.toml)
  assert-true ((validate-config $engine_root $missing_dependency_config) | any {|issue| $issue.area == mise and ($issue.message | str contains "requires 'node'") }) "config reports missing npm backend dependency"
  let dependency_config = ($config
    | upsert software.mise.configs [tests/fixtures/mise.complete.toml]
    | upsert software.mise.manager_config tests/fixtures/mise.complete.toml)
  assert-equal (mise-install-plan $engine_root $dependency_config | get tool) [node rust python null] "mise install dependency command order"
  assert-equal (uv-package-record "ruff") {spec: ruff name: ruff version: null commands: []} "unversioned uv package"
  assert-equal (uv-package-record "ruff==0.12.0") {spec: "ruff==0.12.0" name: ruff version: "0.12.0" commands: []} "pinned uv package"
  assert-equal (pnpm-package-record "@biomejs/biome") {spec: "@biomejs/biome" name: "@biomejs/biome" version: null commands: []} "unversioned pnpm package"
  assert-equal (pnpm-package-record "@biomejs/biome@2.1.0") {spec: "@biomejs/biome@2.1.0" name: "@biomejs/biome" version: "2.1.0" commands: []} "pinned pnpm package"
  assert-equal (node-package-record "@biomejs/biome@2.1.0" [biome]) {spec: "@biomejs/biome@2.1.0" name: "@biomejs/biome" version: "2.1.0" commands: [biome]} "node package command mapping"
}

# Package specifier parsing and per-manager install/update semantics.
def test-spec-parsing [] {
  assert-equal (node-spec-parse "@biomejs/biome@2.1.0") {name: "@biomejs/biome" version: "2.1.0"} "node spec parsing with version"
  assert-equal (node-spec-parse "pkg") {name: pkg version: null} "node spec parsing without version"
  assert-equal (node-spec-parse "pkg@latest") {name: pkg version: latest} "node spec parsing with tag"
  assert-equal (node-spec-parse "pkg@npm:alias") null "node spec rejects npm aliases"
  assert-equal (node-spec-parse "pkg@>=1.0") null "node spec rejects version ranges"
  assert-equal (node-spec-parse "pkg@1.0.0@2.0.0") null "node spec rejects malformed versions"
  assert-equal (uv-spec-parse "ruff==0.12.0") {name: ruff version: "0.12.0"} "uv spec parsing with version"
  assert-equal (uv-spec-parse "ruff") {name: ruff version: null} "uv spec parsing without version"
  assert-equal (uv-spec-parse "ruff~=0.1") null "uv spec rejects version ranges"
  assert-equal (uv-spec-parse "ruff>=1.0") null "uv spec rejects comparison operators"
  assert-equal (node-manager-install-args pnpm "pkg") [add --global pkg] "pnpm install semantics"
  assert-equal (node-manager-install-args yarn "pkg") [global add pkg] "yarn install semantics"
  assert-equal (node-manager-install-args bun "pkg") [add --global pkg] "bun install semantics"
  assert-equal (node-manager-update-args yarn {spec: pkg name: pkg version: null commands: []}) [global upgrade --latest pkg] "yarn update semantics"
  assert-equal (node-manager-update-args bun {spec: pkg name: pkg version: null commands: []}) [update --global pkg] "bun update semantics"
  assert-equal (node-yarn-major-version "1.22.19") 1 "yarn 1 major version"
  assert-equal (node-yarn-major-version "4.1.0") 4 "yarn 4 major version"
  assert-equal (node-yarn-major-version "unparseable") 0 "unparseable yarn version defaults to 0"
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
  assert-equal (uv-packages $engine_root $versioned_uv_config) ["ruff==0.12.0"] "versioned uv manifest schema"
  assert-equal (pnpm-packages $engine_root $versioned_pnpm_config) ["@biomejs/biome@2.1.0"] "versioned pnpm manifest schema"
  let invalid_manager_manifest_config = ($config | upsert software.mise.uv.manifests [tests/fixtures/manager-invalid.nuon])
  assert-true ((validate-config $engine_root $invalid_manager_manifest_config) | any {|issue| $issue.area == uv and ($issue.message | str contains "command list") }) "manager command schema validation"
  let invalid_uv_spec_config = ($config | upsert software.mise.uv.manifests [tests/fixtures/uv-invalid-spec.nuon])
  assert-true ((validate-config $engine_root $invalid_uv_spec_config) | any {|issue| $issue.area == uv and ($issue.message | str contains "Unsupported package specifier") }) "uv manifest rejects unsupported specifiers"
  let invalid_node_spec_config = ($config
    | upsert software.mise.bun.enabled true
    | upsert software.mise.bun.manifests [tests/fixtures/node-invalid-spec.nuon])
  assert-true ((validate-config $engine_root $invalid_node_spec_config) | any {|issue| $issue.area == bun and ($issue.message | str contains "Unsupported package specifier") }) "node manifest rejects unsupported specifiers"
  assert-true (try { uv-entries $engine_root $invalid_uv_spec_config; false } catch { true }) "uv entries reject unsupported specifiers"
  assert-true (try { node-manager-entries $engine_root $invalid_node_spec_config bun; false } catch { true }) "node manager entries reject unsupported specifiers"
}

# Inventory output parsing for every package manager.
def test-inventory-parsing [] {
  assert-equal (parse-uv-inventory "ruff v0.12.0\nother output") [{name: ruff version: "0.12.0"}] "uv inventory parsing"
  let pnpm_inventory = (parse-pnpm-inventory ({dependencies: {"@biomejs/biome": {version: "2.1.0"} ruff: {version: "1.0.0"}}}))
  assert-equal $pnpm_inventory [{name: "@biomejs/biome" version: "2.1.0"} {name: ruff version: "1.0.0"}] "pnpm inventory parsing"
  assert-equal (parse-node-dependency-inventory ({dependencies: {"@biomejs/biome": {version: "2.1.0"}}})) [{name: "@biomejs/biome" version: "2.1.0"}] "node dependency inventory parsing"
  assert-equal (parse-yarn-inventory '{"type":"tree","data":[{"name":"@biomejs/biome@2.1.0"},{"name":"ruff@1.0.0"}]}') [{name: "@biomejs/biome" version: "2.1.0"} {name: ruff version: "1.0.0"}] "yarn inventory parsing"
  assert-equal (parse-bun-inventory "C:\\bun\\install\\global node_modules (2)\n-- @biomejs/biome@2.1.0\n-- ruff@1.0.0") [{name: "@biomejs/biome" version: "2.1.0"} {name: ruff version: "1.0.0"}] "bun inventory parsing"
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
  assert-equal (uv-missing-packages $desired_unpinned [{name: ruff version: "0.11.0"}]) [] "unpinned uv presence check"
  assert-equal (uv-missing-packages $desired_pinned $installed_version) [] "pinned uv version check"
  assert-equal (uv-missing-packages $desired_pinned [{name: ruff version: "0.11.0"}] | get spec) ["ruff==0.12.0"] "pinned uv mismatch"
  assert-equal (pnpm-missing-packages [{spec: "@biomejs/biome" name: "@biomejs/biome" version: null}] [{name: "@biomejs/biome" version: "1.0.0"}]) [] "unpinned pnpm presence check"
  assert-equal (pnpm-missing-packages [{spec: "@biomejs/biome@2.1.0" name: "@biomejs/biome" version: "2.1.0"}] [{name: "@biomejs/biome" version: "1.0.0"}] | get spec) ["@biomejs/biome@2.1.0"] "pinned pnpm mismatch"
  assert-equal (node-manager-missing-packages [{spec: "@biomejs/biome" name: "@biomejs/biome" version: null commands: [biome]}] [{name: "@biomejs/biome" version: "1.0.0"}]) [] "unpinned node manager presence check"
  assert-equal (managed-command-checks pnpm [{spec: "@biomejs/biome" name: "@biomejs/biome" version: null commands: [biome]}] | get check) ["managed binary: biome"] "declared command verification"
}

# Mise configuration validation: manager config selection, config naming,
# and task file presence.
def test-mise-config-validation [
  state_root: path # Private state template root.
] {
  let config = (load-config $state_root [personal])
  let invalid_manager_config = ($config | upsert software.mise.manager_config missing.toml)
  assert-true ((validate-config $state_root $invalid_manager_config) | any {|issue| $issue.area == mise and ($issue.message | str contains "manager_config") }) "manager config selection validation"
  assert-true ((mise-manager-config $state_root $config) | path exists) "manager config resolves to an existing file"

  let invalid_mise = ($config | upsert software.mise.configs [tools.custom.toml])
  let invalid_issues = (validate-config $state_root $invalid_mise)
  assert-true ($invalid_issues | any {|issue| $issue.area == mise and ($issue.message | str contains "Unsupported config name") }) "mise config names are validated"
  let missing_task = ($config | upsert software.mise.task_files [scripts/missing.nu])
  assert-true ((validate-config $state_root $missing_task) | any {|issue| $issue.area == mise and ($issue.message | str contains "Missing mise task file") }) "mise task files are validated"
}

# Checkpoint scoping and desired-state fingerprints.
def test-checkpoints [
  engine_root: path # Engine root.
  state_root: path # Private state template root.
] {
  let config = (load-config $state_root [personal])
  let checkpoint = (checkpoint-path $config | path basename)
  assert-true ($checkpoint | str contains "personal") "checkpoint is profile-specific"
  let state_fingerprint = (config-fingerprint $state_root $config)
  let restore_fingerprint = (config-fingerprint $state_root $config --engine-root=$engine_root)
  assert-equal ($state_fingerprint | str length) 64 "desired-state fingerprint"
  assert-equal ($restore_fingerprint | str length) 64 "engine-aware restore fingerprint"
  assert-true ($state_fingerprint != $restore_fingerprint) "engine changes invalidate restore checkpoints"
}

def main [] {
  let engine_root = ($env.FILE_PWD | path dirname)
  let state_root = ($engine_root | path join "templates" "state")

  test-config-layer $state_root
  test-manager-entries $engine_root $state_root
  test-bootstrap-contract
  test-cargo-binstall $engine_root $state_root
  test-winget-manifests $engine_root $state_root
  test-brewfile-manifests $engine_root $state_root
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
