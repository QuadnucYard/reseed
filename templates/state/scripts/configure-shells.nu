#!/usr/bin/env nu

const loader_begin = "# >>> Reseed managed tools >>>"
const loader_end = "# <<< Reseed managed tools <<<"

# Save generated content through a sibling temporary file so a failed restore
# cannot leave a partially written shell program.
def save-text [path: path content: string] {
  mkdir ($path | path dirname)
  let temporary = $"($path).(random uuid).tmp"
  $content | save --force $temporary
  mv --force $temporary $path
}

def save-lines [path: path lines: list<string>] {
  save-text $path (($lines | str join "\n") + "\n")
}

# Quote an absolute path for generated shell source.
def quote-shell [value: string syntax: string]: nothing -> string {
  let normalized = if $syntax in [fish posix] { $value | str replace --all "\\" "/" } else { $value }
  match $syntax {
    nu => ($normalized | to nuon)
    fish => {
      let escaped = ($normalized
        | str replace --all "\\" "\\\\"
        | str replace --all '"' '\\"'
        | str replace --all '$' '\\$')
      '"' + $escaped + '"'
    }
    powershell => ("'" + ($normalized | str replace --all "'" "''") + "'")
    _ => ("'" + ($normalized | str replace --all "'" "'\\''") + "'")
  }
}

def run-generated-command [program: string args: list<string> label: string]: nothing -> string {
  let result = (try {
    run-external $program ...$args | complete
  } catch {|error|
    {exit_code: 127 stdout: "" stderr: ($error.msg? | default ($error | to nuon))}
  })
  if $result.exit_code != 0 {
    let detail = if ($result.stderr | str trim | is-empty) { $result.stdout | str trim } else { $result.stderr | str trim }
    error make {msg: $"Failed to generate ($label): ($detail)"}
  }
  $result.stdout
}

def detected-homebrew-prefix []: nothing -> any {
  let declared = ($env.HOMEBREW_PREFIX? | default "" | str trim)
  if not ($declared | is-empty) and ($declared | path exists) {
    return ($declared | path expand --no-symlink)
  }

  let standard = [
    /opt/homebrew/bin/brew
    /usr/local/bin/brew
    /home/linuxbrew/.linuxbrew/bin/brew
    ($nu.home-dir | path join ".linuxbrew" "bin" "brew")
  ] | where {|candidate| $candidate | path exists }
  let programs = if (which brew | is-empty) { $standard } else { [brew] | append $standard }
  for program in $programs {
    let result = (try { run-external $program "--prefix" | complete } catch { {exit_code: 1 stdout: "" stderr: ""} })
    if $result.exit_code == 0 and not (($result.stdout | str trim) | is-empty) {
      return ($result.stdout | str trim | path expand --no-symlink)
    }
  }
  null
}

# Only command discovery is exposed to shells. Managers keep native roots.
def normal-root [key: string fallback: path home: path]: nothing -> path {
  let value = ($env | get -o $key | default "")
  let legacy = ($home | path join ".local" "share" "reseed")
  let normalize = {|p|
    let key = ($p | into string | str replace --all "\\" "/" | str trim --right --char "/")
    if $nu.os-info.name == "windows" { $key | str lowercase } else { $key }
  }
  let normalized = (do $normalize $value)
  let user_legacy = ($nu.home-dir | path join ".local" "share" "reseed")
  let old = [$legacy ($legacy | path join "bin") $user_legacy ($user_legacy | path join "bin")] | each $normalize
  if ($value | str trim | is-empty) or $normalized in $old { $fallback } else { $value }
}

def normal-manager-roots [home: path cargo_bin: path]: nothing -> record {
  let local = if ($home | path expand --no-symlink) == ($nu.home-dir | path expand --no-symlink) {
    $env.LOCALAPPDATA? | default ($home | path join "AppData" "Local")
  } else { $home | path join "AppData" "Local" }
  let xdg_data = ($env.XDG_DATA_HOME? | default "")
  let pnpm_default = if not ($xdg_data | str trim | is-empty) { $xdg_data | path join "pnpm" } else if $nu.os-info.name == "windows" { $local | path join "pnpm" } else if $nu.os-info.name == "macos" {
    $home | path join "Library" "pnpm"
  } else { $home | path join ".local" "share" "pnpm" }
  let pnpm = (normal-root PNPM_HOME $pnpm_default $home)
  let bun = (normal-root BUN_INSTALL ($home | path join ".bun") $home)
  let uv = (normal-root UV_TOOL_BIN_DIR ($home | path join ".local" "bin") $home)
  let yarn_default = if $nu.os-info.name == "windows" { $local | path join "Yarn" } else { $home | path join ".yarn" }
  let yarn = (normal-root YARN_PREFIX $yarn_default $home)
  {BUN_INSTALL: $bun PNPM_HOME: $pnpm UV_TOOL_BIN_DIR: $uv YARN_PREFIX: $yarn CARGO_INSTALL_ROOT: (normal-root CARGO_INSTALL_ROOT ($cargo_bin | path dirname) $home)}
}

def normal-bin-dirs [roots: record]: nothing -> list<path> {
  [($roots.CARGO_INSTALL_ROOT | path join "bin") ($roots.BUN_INSTALL | path join "bin") $roots.UV_TOOL_BIN_DIR $roots.PNPM_HOME ($roots.PNPM_HOME | path join "bin") ($roots.YARN_PREFIX | path join "bin")] | uniq
}

def nu-path-lines [directories: list<path> migration_roots: record]: nothing -> list<string> {
  [
    "def --env reseed-normal-path [] {"
    "  let legacy = ($nu.home-dir | path join '.local' 'share' 'reseed' | into string)"
    "  let key = {|p|"
    "    let normalized = ($p | into string | str replace --all '\\' '/' | str trim --right --char '/')"
    "    if $nu.os-info.name == 'windows' { $normalized | str lowercase } else { $normalized }"
    "  }"
    "  let roots = [$legacy ($legacy | path join 'bin')] | each $key"
    # Null removals are discarded by some Nushell startup loader versions.
    # Only inherited legacy values are replaced with their native locations.
    $"  let migration_roots = ($migration_roots | to nuon)"
    "  for name in [BUN_INSTALL PNPM_HOME YARN_PREFIX UV_TOOL_BIN_DIR CARGO_INSTALL_ROOT] {"
    "    let value = ($env | get -o $name | default '')"
    "    if (do $key $value) in $roots { load-env {($name): ($migration_roots | get $name)} }"
    "  }"
    "  let paths = [$legacy ($legacy | path join 'bin') ($legacy | path join 'bin' 'bin')] | skip 1 | each $key"
    "  $env.PATH = ($env.PATH | where {|p| (do $key $p) not-in $paths })"
    $"  let directories = ($directories | to nuon)"
    "  for directory in $directories {"
    "    if ($directory | path exists) {"
    "      let key = ($directory | into string | str replace --all \"\\\\\" \"/\" | str trim --right --char \"/\")"
    "      let present = ($env.PATH | any {|p|"
    "        let other = ($p | into string | str replace --all \"\\\\\" \"/\" | str trim --right --char \"/\")"
    "        if $nu.os-info.name == \"windows\" { ($other | str lowercase) == ($key | str lowercase) } else { $other == $key }"
    "      })"
    "      if not $present { $env.PATH = ($env.PATH | append $directory) }"
    "    }"
    "  }"
    "}"
    "reseed-normal-path"
  ]
}

def write-nushell-environment [path: path directories: list<path> migration_roots: record mise_config: path] {
  save-lines $path (["# Generated by Reseed; package-manager roots are not overridden."]
    | append (nu-path-lines $directories $migration_roots)
    | append $"$env.MISE_GLOBAL_CONFIG_FILE = (quote-shell ($mise_config | into string) nu)")
}

def write-fish-adapter [path: path directories: list<path> mise_config: path] {
  mut lines = [
    "# Generated by Reseed; package-manager roots are not overridden."
    "set -l reseed_legacy $HOME/.local/share/reseed"
    "for name in BUN_INSTALL PNPM_HOME YARN_PREFIX UV_TOOL_BIN_DIR CARGO_INSTALL_ROOT"
    "    if set -q $name; and contains -- $$name $reseed_legacy $reseed_legacy/bin"
    "        set -e $name"
    "    end"
    "end"
    "set -l reseed_clean_path"
    "for directory in $PATH"
    "    if not contains -- $directory $reseed_legacy/bin $reseed_legacy/bin/bin"
    "        set -a reseed_clean_path $directory"
    "    end"
    "end"
    "set -gx PATH $reseed_clean_path"
  ]
  for directory in $directories {
    $lines = ($lines | append [
      $"if test -d (quote-shell ($directory | into string) fish)"
      $"    fish_add_path --append --path (quote-shell ($directory | into string) fish)"
      "end"
    ])
  }
  save-lines $path ($lines | append [
    $"set -gx MISE_GLOBAL_CONFIG_FILE (quote-shell ($mise_config | into string) fish)"
    "if command -q mise"
    "    mise activate fish | source"
    "else"
    "    echo 'reseed: mise is unavailable; runtime activation was skipped' >&2"
    "end"
  ])
}

def write-powershell-adapter [path: path directories: list<path> mise_config: path] {
  mut lines = [
    "# Generated by Reseed; package-manager roots are not overridden."
    "$reseedLegacy = (Join-Path $HOME '.local/share/reseed').Replace('\\', '/').TrimEnd('/')"
    "foreach ($name in @('BUN_INSTALL','PNPM_HOME','YARN_PREFIX','UV_TOOL_BIN_DIR','CARGO_INSTALL_ROOT')) {"
    "    $value = [Environment]::GetEnvironmentVariable($name, 'Process')"
    "    if ($value -and $value.Replace('\\', '/').TrimEnd('/') -in @($reseedLegacy, ($reseedLegacy + '/bin'))) {"
    "        Remove-Item -LiteralPath (\"Env:\" + $name) -ErrorAction SilentlyContinue"
    "    }"
    "}"
    "$env:Path = (($env:Path -split [IO.Path]::PathSeparator | Where-Object { $_.Replace('\\', '/').TrimEnd('/') -notin @(($reseedLegacy + '/bin'), ($reseedLegacy + '/bin/bin')) }) -join [IO.Path]::PathSeparator)"
    "Remove-Variable reseedLegacy, name, value -ErrorAction SilentlyContinue"
    "function Add-ReseedPath([string] $Directory) {"
    "    $key = $Directory.Replace('\\', '/').TrimEnd('/')"
    "    $present = @($env:Path -split [IO.Path]::PathSeparator | Where-Object { $_.Replace('\\', '/').TrimEnd('/') -ieq $key }).Count -gt 0"
    "    if ((Test-Path -LiteralPath $Directory) -and -not $present) {"
    "        $env:Path = \"$env:Path$([IO.Path]::PathSeparator)$Directory\""
    "    }"
    "}"
  ]
  for directory in $directories {
    $lines = ($lines | append $"Add-ReseedPath (quote-shell ($directory | into string) powershell)")
  }
  save-lines $path ($lines | append [
    "Remove-Item -LiteralPath Function:\\Add-ReseedPath"
    $"$env:MISE_GLOBAL_CONFIG_FILE = (quote-shell ($mise_config | into string) powershell)"
    "if (Get-Command mise -ErrorAction SilentlyContinue) {"
    "    mise activate pwsh | Out-String | Invoke-Expression"
    "} else {"
    "    Write-Warning 'Reseed: mise is unavailable; runtime activation was skipped'"
    "}"
  ])
}

def posix-adapter-lines [shell: string directories: list<path> mise_config: path]: nothing -> list<string> {
  mut lines = [
    "# Generated by Reseed; package-manager roots are not overridden."
    "reseed_legacy=$HOME/.local/share/reseed"
    "case ${BUN_INSTALL-} in \"$reseed_legacy\"|\"$reseed_legacy/bin\") unset BUN_INSTALL ;; esac"
    "case ${PNPM_HOME-} in \"$reseed_legacy\"|\"$reseed_legacy/bin\") unset PNPM_HOME ;; esac"
    "case ${YARN_PREFIX-} in \"$reseed_legacy\"|\"$reseed_legacy/bin\") unset YARN_PREFIX ;; esac"
    "case ${UV_TOOL_BIN_DIR-} in \"$reseed_legacy\"|\"$reseed_legacy/bin\") unset UV_TOOL_BIN_DIR ;; esac"
    "case ${CARGO_INSTALL_ROOT-} in \"$reseed_legacy\"|\"$reseed_legacy/bin\") unset CARGO_INSTALL_ROOT ;; esac"
    "reseed_rest=$PATH; reseed_clean_path=; reseed_separator="
    "while :; do"
    "  case $reseed_rest in *:*) reseed_directory=${reseed_rest%%:*}; reseed_rest=${reseed_rest#*:}; reseed_more=1 ;; *) reseed_directory=$reseed_rest; reseed_more=0 ;; esac"
    "  case $reseed_directory in \"$reseed_legacy/bin\"|\"$reseed_legacy/bin/bin\") ;; *) reseed_clean_path=$reseed_clean_path$reseed_separator$reseed_directory; reseed_separator=: ;; esac"
    "  [ $reseed_more = 1 ] || break"
    "done"
    "PATH=$reseed_clean_path"
    "unset reseed_legacy reseed_rest reseed_clean_path reseed_separator reseed_directory reseed_more"
    "reseed_append_path() {"
    "  case :$PATH: in *\":$1:\"*) ;; *) PATH=$PATH:$1 ;; esac"
    "}"
  ]
  for directory in $directories {
    $lines = ($lines | append $"[ ! -d (quote-shell ($directory | into string) posix) ] || reseed_append_path (quote-shell ($directory | into string) posix)")
  }
  $lines = ($lines | append [
    "export PATH"
    $"export MISE_GLOBAL_CONFIG_FILE=(quote-shell ($mise_config | into string) posix)"
    "unset -f reseed_append_path 2>/dev/null || true"
  ])
  let activation = match $shell {
    bash => "if command -v mise >/dev/null 2>&1; then eval \"$(mise activate bash)\"; else echo 'reseed: mise is unavailable; runtime activation was skipped' >&2; fi"
    zsh => "if command -v mise >/dev/null 2>&1; then eval \"$(mise activate zsh)\"; else echo 'reseed: mise is unavailable; runtime activation was skipped' >&2; fi"
    _ => "if command -v mise >/dev/null 2>&1; then if [ -n \"${ZSH_VERSION:-}\" ]; then eval \"$(mise activate zsh)\"; elif [ -n \"${BASH_VERSION:-}\" ]; then eval \"$(mise activate bash)\"; fi; else echo 'reseed: mise is unavailable; runtime activation was skipped' >&2; fi"
  }
  $lines | append $activation
}

def chezmoi-manages [state_root: path target: path]: nothing -> bool {
  if (which chezmoi | is-empty) { return false }
  let result = (try {
    ^chezmoi --source ($state_root | into string) source-path ($target | into string) | complete
  } catch {
    {exit_code: 1 stdout: "" stderr: ""}
  })
  ($result.exit_code == 0) and not (($result.stdout | str trim) | is-empty)
}

# Install or refresh the Reseed-owned block in an unmanaged profile. A profile
# owned by chezmoi remains authoritative and must already source the adapter.
def profile-sources-adapter [content: string adapter: path]: nothing -> bool {
  ($content | str contains ($adapter | into string)) or ($content | str contains ($adapter | path basename))
}

def ensure-profile-loader [
  profile: path
  adapter: path
  loader: string
  state_root: path
] {
  let existing = if ($profile | path exists) { open --raw $profile } else { "" }
  if (chezmoi-manages $state_root $profile) {
    if not (profile-sources-adapter $existing $adapter) {
      error make {msg: $"Chezmoi-managed profile must source the generated adapter: ($profile) -> ($adapter)"}
    }
    return
  }

  let pattern = '(?ms)^# >>> Reseed managed tools >>>\r?\n.*?^# <<< Reseed managed tools <<<\r?\n?'
  let stripped = ($existing | str replace --all --regex $pattern "")
  let separator = if ($stripped | is-empty) or ($stripped | str ends-with "\n\n") {
    ""
  } else if ($stripped | str ends-with "\n") {
    "\n"
  } else {
    "\n\n"
  }
  let prefix = $stripped + $separator
  save-text $profile ($prefix + $loader_begin + "\n" + $loader + "\n" + $loader_end + "\n")
}

def detected-powershell-profile [program: string]: nothing -> any {
  let result = (try {
    run-external $program "-NoLogo" "-NoProfile" "-Command" '$PROFILE.CurrentUserCurrentHost' | complete
  } catch {
    {exit_code: 1 stdout: "" stderr: ""}
  })
  let profile = ($result.stdout | str trim)
  if $result.exit_code == 0 and not ($profile | is-empty) {
    $profile | path expand --no-symlink
  } else {
    null
  }
}

def powershell-profile-paths [home: path]: nothing -> list<path> {
  let fallbacks = if $nu.os-info.name == "windows" {
    [
      ($home | path join "Documents" "PowerShell" "Microsoft.PowerShell_profile.ps1")
      ($home | path join "Documents" "WindowsPowerShell" "Microsoft.PowerShell_profile.ps1")
    ]
  } else {
    [($home | path join ".config" "powershell" "Microsoft.PowerShell_profile.ps1")]
  }
  if ($home | path expand --no-symlink) != ($nu.home-dir | path expand --no-symlink) {
    return $fallbacks
  }

  let programs = if $nu.os-info.name == "windows" { [pwsh powershell] } else { [pwsh] }
  let detected = ($programs | each {|program| detected-powershell-profile $program } | compact | uniq)
  if ($detected | is-empty) { $fallbacks } else { $detected }
}

def install-profile-loaders [
  home: path
  state_root: path
  bash_adapter: path
  zsh_adapter: path
  powershell_adapter: path
] {
  ensure-profile-loader ($home | path join ".bashrc") $bash_adapter $". (quote-shell ($bash_adapter | into string) posix)" $state_root
  ensure-profile-loader ($home | path join ".zshrc") $zsh_adapter $". (quote-shell ($zsh_adapter | into string) posix)" $state_root

  for profile in (powershell-profile-paths $home) {
    ensure-profile-loader $profile $powershell_adapter $". (quote-shell ($powershell_adapter | into string) powershell)" $state_root
  }
}

def remove-generated [paths: list<path>] {
  for path in $paths {
    if ($path | path exists) { rm --force $path }
  }
}

def remove-nushell-generated [autoload: path] {
  remove-generated [
    ($autoload | path join "mise.nu")
    ($autoload | path join "reseed-10-environment.nu")
    ($autoload | path join "reseed-20-mise.nu")
    ($autoload | path join "reseed-managed-tools.nu")
    ($autoload | path join "starship.nu")
  ]
}

def main [
  --home: path = $nu.home-dir # Home directory for generated adapters and loaders.
  --data-dir: path = $nu.data-dir # Nushell data directory for autoload files.
  --mise-config: path = "" # Mise config exposed to interactive shells.
  --state-root: path = "" # Chezmoi source used to protect managed profiles.
  --cargo-home: path = "" # Cargo home whose bin directory is the rustup fallback.
  --xdg-config-home: path = "" # XDG config root containing Fish configuration.
  --skip-profile-loaders # Generate adapters without changing shell profiles.
  --starship-init-source: path = "" # Pre-generated Starship source for isolated/offline generation.
  --mise-activation-source: path = "" # Pre-generated mise source for isolated/offline generation.
] {
  let use_starship_source = not (($starship_init_source | into string | str trim) | is-empty)
  let use_mise_source = not (($mise_activation_source | into string | str trim) | is-empty)
  let nu_autoload_dir = ($data_dir | path join "vendor" "autoload")
  if not $use_starship_source and (which starship | is-empty) {
    remove-nushell-generated $nu_autoload_dir
    error make {msg: "starship is required before shell integration is configured"}
  }
  if not $use_mise_source and (which mise | is-empty) {
    remove-nushell-generated $nu_autoload_dir
    error make {msg: "mise is required before shell integration is configured"}
  }

  let configured_mise = if not (($mise_config | into string | str trim) | is-empty) {
    $mise_config
  } else if not (($env.RESEED_MISE_CONFIG_FILE? | default "" | str trim) | is-empty) {
    $env.RESEED_MISE_CONFIG_FILE
  } else {
    $env.FILE_PWD | path dirname | path join "mise.toml"
  }
  let configured_root = if not (($state_root | into string | str trim) | is-empty) {
    $state_root
  } else if not (($env.RESEED_STATE_ROOT? | default "" | str trim) | is-empty) {
    $env.RESEED_STATE_ROOT
  } else {
    $configured_mise | path dirname
  }
  let mise_config_path = ($configured_mise | path expand --no-symlink)
  let state_root_path = ($configured_root | path expand --no-symlink)
  if not ($mise_config_path | path exists) {
    error make {msg: $"Selected mise shell config does not exist: ($mise_config_path)"}
  }

  let configured_cargo_home = if not (($cargo_home | into string | str trim) | is-empty) {
    $cargo_home
  } else if not (($env.CARGO_HOME? | default "" | str trim) | is-empty) {
    $env.CARGO_HOME
  } else {
    $home | path join ".cargo"
  }
  let configured_xdg_home = if not (($xdg_config_home | into string | str trim) | is-empty) {
    $xdg_config_home
  } else if not (($env.XDG_CONFIG_HOME? | default "" | str trim) | is-empty) {
    $env.XDG_CONFIG_HOME
  } else {
    $home | path join ".config"
  }

  let managed_root = ($home | path join ".local" "share" "reseed")
  let cargo_bin = ($configured_cargo_home | path expand --no-symlink | path join "bin")
  let fish_config_home = ($configured_xdg_home | path expand --no-symlink)
  let managed_shell = ($managed_root | path join "shell")
  let brew_prefix = (detected-homebrew-prefix)
  let starship_init = ($nu_autoload_dir | path join "starship.nu")
  let nu_environment = ($nu_autoload_dir | path join "reseed-10-environment.nu")
  let nu_mise = ($nu_autoload_dir | path join "reseed-20-mise.nu")
  let fish_adapter = ($fish_config_home | path join "fish" "conf.d" "reseed-managed-tools.fish")
  let powershell_adapter = ($managed_shell | path join "reseed-managed-tools.ps1")
  let bash_adapter = ($managed_shell | path join "reseed-managed-tools.bash")
  let zsh_adapter = ($managed_shell | path join "reseed-managed-tools.zsh")
  let posix_adapter = ($managed_shell | path join "reseed-managed-tools.sh")

  let starship_source = if $use_starship_source {
    if not ($starship_init_source | path exists) { error make {msg: $"Starship init source does not exist: ($starship_init_source)"} }
    open --raw $starship_init_source
  } else {
    run-generated-command starship [init nu] "Nushell Starship activation"
  }
  let mise_source = (try {
    if $use_mise_source {
      if not ($mise_activation_source | path exists) { error make {msg: $"Mise activation source does not exist: ($mise_activation_source)"} }
      open --raw $mise_activation_source
    } else {
      run-generated-command mise [activate nu --no-hook-env] "Nushell mise activation"
    }
  } catch {|error|
    remove-nushell-generated $nu_autoload_dir
    error make {msg: ($error.msg? | default ($error | to nuon))}
  })
  save-text $starship_init $starship_source
  let migration_roots = (normal-manager-roots $home $cargo_bin)
  mut directories = (normal-bin-dirs $migration_roots | append $cargo_bin | uniq)
  if $brew_prefix != null { $directories = ($directories | append [($brew_prefix | path join "bin") ($brew_prefix | path join "sbin")]) }
  write-nushell-environment $nu_environment $directories $migration_roots $mise_config_path
  # The initial hook runs at shell startup, not while this file is generated.
  # Reapply only native bin discovery after directory/prompt updates, never a PATH snapshot.
  let live_mise = if $use_mise_source { $mise_source } else {
    let helpers = (nu-path-lines $directories $migration_roots | str join "\n")
    let activation = ($mise_source | str replace --all "| update-env" "| update-env\n  reseed-normal-path")
    $helpers + "\n" + $activation + "\nexport-env { mise_hook }\n"
  }
  save-text $nu_mise $live_mise
  write-fish-adapter $fish_adapter $directories $mise_config_path
  write-powershell-adapter $powershell_adapter $directories $mise_config_path
  save-lines $bash_adapter (posix-adapter-lines bash $directories $mise_config_path)
  save-lines $zsh_adapter (posix-adapter-lines zsh $directories $mise_config_path)
  save-lines $posix_adapter (posix-adapter-lines dispatch $directories $mise_config_path)

  remove-generated [
    ($nu_autoload_dir | path join "mise.nu")
    ($nu_autoload_dir | path join "reseed-managed-tools.nu")
  ]
  if not $skip_profile_loaders {
    install-profile-loaders $home $state_root_path $bash_adapter $zsh_adapter $powershell_adapter
  }

  print $"reseed: selected mise shell config: ($mise_config_path)"
  print $"reseed: Nushell autoload directory: ($nu_autoload_dir)"
  print "reseed: package commands use native manager directories"
  print $"reseed: shell adapters: ($managed_shell)"
}
