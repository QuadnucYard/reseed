# SSH setup steps: the agent, the default key, GitHub registration, remote
# host key installation (including the admin allow list), ssh config
# entries, and connectivity tests.

use ../core.nu [command-exists detect-os expand-home run-command info warning]
use ./shared.nu [machine-name ssh-agent-running ssh-key-status]
use ./git.nu [git-config-get]

# Whether the local public SSH key is already registered on GitHub.
export def github-has-ssh-key []: nothing -> bool {
  if not (command-exists gh) { return false }
  let key = (ssh-key-status)
  if not $key.key_present { return false }
  let local = (open --raw $key.pub_path | str trim)
  let listing = (run-command gh ["ssh-key" "list" "--json" "key"] --allow-failure --quiet --capture)
  if $listing.exit_code != 0 { return false }
  let keys = (try { $listing.stdout | from json | get key } catch { return false })
  ($keys | any {|remote| ($remote | str trim) == $local })
}

# Normalized configured host entries.
export def setup-hosts [config: record]: nothing -> list<record> {
  let hosts = ((($config.setup? | default {}).ssh? | default {}).hosts? | default [])
  $hosts | each {|host| {
    name: ($host.name? | default ($host.host? | default ""))
    user: ($host.user? | default "")
    host: ($host.host? | default "")
    port: ($host.port? | default 22)
    admin: ($host.admin? | default false)
    os: ($host.os? | default "unix")
  }}
}

# True when no remote SSH hosts are configured.
export def ssh-hosts-empty [config: record]: nothing -> bool {
  (setup-hosts $config | is-empty)
}

# Normalize one host record for storage and comparison.
export def normalize-ssh-host [user: string, host: string, port: int = 22, admin: bool = false, os: string = "unix", name: string = ""]: nothing -> record {
  let address = ($host | str trim)
  let alias = ($name | str trim)
  {name: (if ($alias | is-empty) { $address } else { $alias }) user: ($user | str trim) host: $address port: $port admin: $admin os: ($os | str lowercase | str trim)}
}

# Whether a host with the same hostname and port is already configured.
export def ssh-host-duplicate [config: record, candidate: record]: nothing -> bool {
  let hostname = ($candidate.host | str lowercase)
  let port = $candidate.port
  (setup-hosts $config | any {|host| (($host.host | str lowercase) == $hostname) and $host.port == $port })
}

export def ssh-host-name-duplicate [config: record, candidate: record]: nothing -> bool {
  let name = ($candidate.name | str lowercase)
  (setup-hosts $config | any {|host| ($host.name | str lowercase) == $name })
}

def container-end [tokens: table, start: int, shape: string, opener: string, closer: string]: nothing -> int {
  mut depth = 0
  for row in ($tokens | enumerate | skip $start) {
    if ($row.item.shape | into string) != $shape { continue }
    let content = ($row.item.content | str trim)
    if ($content | str starts-with $opener) { $depth += 1 }
    if ($content | str ends-with $closer) { $depth -= 1 }
    if $depth == 0 { return $row.item.span.end }
  }
  -1
}

def key-value-span [tokens: table, key: string, start: int = 0, end: int = 9223372036854775807]: nothing -> any {
  let key_row = ($tokens | enumerate | where {|row|
    $row.item.shape == shape_string and $row.item.content == $key and $row.item.span.start >= $start and $row.item.span.end <= $end
  } | get -o 0)
  if $key_row == null { return null }
  let value_row = ($tokens | enumerate | skip ($key_row.index + 1) | where {|row|
    let content = ($row.item.content | str trim)
    ($row.item.shape == shape_list and ($content | str starts-with "[")) or ($row.item.shape == shape_record and ($content | str starts-with "{"))
  } | get -o 0)
  if $value_row == null { return null }
  let shape = ($value_row.item.shape | into string)
  let bounds = if $shape == "shape_list" {
    {end: (container-end $tokens $value_row.index shape_list "[" "]")}
  } else {
    {end: (container-end $tokens $value_row.index shape_record "{" "}")}
  }
  {start: $value_row.item.span.start end: $bounds.end index: $value_row.index shape: $shape}
}

# Replace the parsed `setup.ssh.hosts` value while retaining all other source
# text, including comments. Missing sections fall back to a valid NUON rewrite.
export def ssh-hosts-source-update [source: string, config: record, hosts: list<record>]: nothing -> string {
  let updated = ($config | upsert setup ( (($config.setup? | default {}) | upsert ssh ((($config.setup?.ssh? | default {}) | upsert hosts $hosts))) ))
  let tokens = (ast $source --flatten)
  let setup = (key-value-span $tokens setup)
  let rendered = ($hosts | each {|host| $host | to nuon } | str join "\n" | prepend "[" | append "]" | str join "\n")
  if $setup == null {
    let root_end = (container-end $tokens 0 shape_record "{" "}")
    if $root_end < 1 { return ($updated | to nuon --indent 2) }
    return (($source | str substring 0..($root_end - 2)) + $"\n  setup: {ssh: {hosts: ($rendered)}}" + ($source | str substring ($root_end - 1)..))
  }
  if $setup.shape != "shape_record" { return ($updated | to nuon --indent 2) }
  let ssh = (key-value-span $tokens ssh $setup.start $setup.end)
  if $ssh == null {
    return (($source | str substring 0..($setup.end - 2)) + $"\n    ssh: {hosts: ($rendered)}" + ($source | str substring ($setup.end - 1)..))
  }
  if $ssh.shape != "shape_record" { return ($updated | to nuon --indent 2) }
  let span = (key-value-span $tokens hosts $ssh.start $ssh.end)
  if $span == null {
    return (($source | str substring 0..($ssh.end - 2)) + $"\n      hosts: ($rendered)" + ($source | str substring ($ssh.end - 1)..))
  }
  if $span.shape != "shape_list" { return ($updated | to nuon --indent 2) }
  ($source | str substring 0..($span.start - 1)) + $rendered + ($source | str substring $span.end..)
}

# "user@host" target string.
def ssh-target [host: record]: nothing -> string {
  $"($host.user)@($host.host)"
}

# ssh connection arguments for a host: batch mode, connect timeout, optional
# extras, port, and target.
def ssh-connect-args [host: record, extra: list<string> = []]: nothing -> list<string> {
  ["-o" "BatchMode=yes" "-o" "ConnectTimeout=10"]
    | append $extra
    | append ["-p" ($host.port | into string) (ssh-target $host)]
}

# SSH arguments for bootstrapping a key. Unlike probes, installation permits
# password or keyboard-interactive authentication while retaining a timeout.
export def ssh-install-args [host: record, extra: list<string> = []]: nothing -> list<string> {
  ["-o" "BatchMode=no" "-o" "ConnectTimeout=10" "-o" "NumberOfPasswordPrompts=3"]
    | append $extra
    | append ["-p" ($host.port | into string) (ssh-target $host)]
}

export def ssh-verification-args [host: record, key_path: string]: nothing -> list<string> {
  ssh-connect-args $host ["-i" $key_path "-o" "IdentitiesOnly=yes"]
}

# Whether passwordless login to the host already works.
def host-key-installed [host: record]: nothing -> bool {
  let key = (ssh-key-status)
  if not $key.key_present { return false }
  let args = (ssh-verification-args $host $key.key_path | append "exit 0")
  let probe = (run-command ssh $args --allow-failure --quiet)
  $probe.exit_code == 0
}

# Whether the key is installed on every configured host.
export def hosts-keys-installed [config: record]: nothing -> bool {
  (setup-hosts $config | all {|host| host-key-installed $host })
}

# Path of ~/.ssh/config.
def ssh-config-path []: nothing -> path {
  expand-home "~/.ssh/config"
}

# Whether every configured host already has a Host block in ~/.ssh/config.
export def hosts-in-ssh-config [config: record]: nothing -> bool {
  let path = (ssh-config-path)
  if not ($path | path exists) { return false }
  let existing = (open --raw $path)
  (setup-hosts $config | all {|host| ($existing | lines | any {|line| ($line | str trim) == $"Host ($host.name)" }) })
}

# Generated Host block for one host entry.
def ssh-config-block [host: record]: nothing -> string {
  let port = ($host.port? | default 22)
  let name = ($host.name? | default $host.host)
  [$"Host ($name)" $"HostName ($host.host)" $"User ($host.user)"]
    | append (if $port == 22 { [] } else { [$"Port ($port)"] })
    | str join "\n"
}

# Merge generated Host blocks into an existing ssh config, keeping the Host
# blocks that are already present.
export def ssh-config-merge [existing: string, hosts: list<record>]: nothing -> string {
  let lines = ($existing | lines)
  mut parts = [$existing]
  for host in $hosts {
    let name = ($host.name? | default $host.host)
    if ($lines | any {|line| ($line | str trim) == $"Host ($name)" }) { continue }
    $parts = ($parts | append (ssh-config-block $host))
  }
  $parts
    | where {|part| not (($part | str trim) | is-empty) }
    | str join "\n"
    | str trim
}

# Path of the admin allow list on the target host, per host operating system.
export def admin-key-path [os: string]: nothing -> string {
  match $os {
    windows => "C:\\ProgramData\\ssh\\administrators_authorized_keys"
    macos => "/var/root/.ssh/authorized_keys"
    _ => "/root/.ssh/authorized_keys"
  }
}

# Encode an ASCII-only PowerShell bootstrap script as UTF-16LE Base64. Using
# -EncodedCommand avoids quoting differences between cmd and PowerShell sshd
# default shells.
def powershell-encoded-command [script: string]: nothing -> string {
  let encoded = ($script | split chars | each {|char| $char | encode ascii | bytes add 0x[00] --end } | bytes collect | encode base64)
  $"powershell -NoProfile -NonInteractive -EncodedCommand ($encoded)"
}

export def windows-user-keys-script []: nothing -> string {
  [
      "$ErrorActionPreference = 'Stop'"
      "$directory = Join-Path $HOME '.ssh'"
      "$path = Join-Path $directory 'authorized_keys'"
      "$key = [Console]::In.ReadToEnd().Trim()"
      "if ([string]::IsNullOrWhiteSpace($key)) { throw 'no public key received on stdin' }"
      "New-Item -ItemType Directory -Path $directory -Force | Out-Null"
      "if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType File -Path $path -Force | Out-Null }"
      "$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value"
      "$principal = '*' + $sid + ':F'"
      "& icacls.exe $directory '/inheritance:r' '/grant:r' $principal '*S-1-5-18:F' | Out-Null"
      "if ($LASTEXITCODE -ne 0) { throw ('directory icacls failed with exit code ' + $LASTEXITCODE) }"
      "& icacls.exe $path '/inheritance:r' '/grant:r' $principal '*S-1-5-18:F' | Out-Null"
      "if ($LASTEXITCODE -ne 0) { throw ('authorized_keys icacls failed with exit code ' + $LASTEXITCODE) }"
      "$lines = @(Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)"
      "if ($key -notin $lines) { [IO.File]::AppendAllText($path, $key + [Environment]::NewLine, [Text.UTF8Encoding]::new($false)) }"
  ] | str join "; "
}

# Command that idempotently appends a key read from stdin to the account's
# authorized_keys file, with platform-appropriate permissions.
export def user-keys-command [os: string]: nothing -> string {
  if $os == "windows" {
    powershell-encoded-command (windows-user-keys-script)
  } else {
    "set -e; key=$(cat); test -n \"$key\"; mkdir -p ~/.ssh; chmod 700 ~/.ssh; touch ~/.ssh/authorized_keys; if ! grep -qxF \"$key\" ~/.ssh/authorized_keys; then printf '%s\\n' \"$key\" >> ~/.ssh/authorized_keys; fi; chmod 600 ~/.ssh/authorized_keys"
  }
}

# Command that appends a public key line to the admin allow list on the host.
export def windows-admin-keys-script []: nothing -> string {
  let path = (admin-key-path windows)
  [
    "$ErrorActionPreference = 'Stop'"
    $"$path = '($path)'"
    "$key = [Console]::In.ReadToEnd().Trim()"
    "if ([string]::IsNullOrWhiteSpace($key)) { throw 'no public key received' }"
    "if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType File -Path $path -Force | Out-Null }"
    "& icacls.exe $path '/inheritance:r' '/grant:r' '*S-1-5-32-544:F' '*S-1-5-18:F' | Out-Null"
    "if ($LASTEXITCODE -ne 0) { throw ('icacls failed with exit code ' + $LASTEXITCODE) }"
    "$lines = @(Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)"
    "if ($key -notin $lines) { [IO.File]::AppendAllText($path, $key + [Environment]::NewLine, [Text.UTF8Encoding]::new($false)) }"
  ] | str join "; "
}

export def admin-keys-command [os: string]: nothing -> string {
  if $os == "windows" {
    powershell-encoded-command (windows-admin-keys-script)
  } else {
    let path = (admin-key-path $os)
    [
      "set -e"
      "key=$(cat)"
      "test -n \"$key\""
      $"path='($path)'"
      "directory=$(dirname \"$path\")"
      "mkdir -p \"$directory\""
      "chmod 700 \"$directory\""
      "touch \"$path\""
      "if ! grep -qxF \"$key\" \"$path\"; then printf '%s\\n' \"$key\" >> \"$path\"; fi"
      "chmod 600 \"$path\""
    ] | str join "; "
  }
}

# Start the OpenSSH agent (Windows service or macOS launchd) and add the
# default key.
export def setup-ssh-agent [
  --dry-run # Show the agent commands without running them.
]: nothing -> record {
  let key = (ssh-key-status)
  if not (ssh-agent-running) {
    if $dry_run {
      return {step: ssh-agent ok: true detail: "would start the SSH agent and add the key"}
    }
    if (detect-os) == "windows" {
      run-command powershell ["-NoProfile" "-Command" "Set-Service ssh-agent -StartupType Automatic"] --allow-failure | ignore
      run-command powershell ["-NoProfile" "-Command" "Start-Service ssh-agent"] --allow-failure | ignore
      if not (ssh-agent-running) {
        return {step: ssh-agent ok: false detail: "the SSH agent did not start; run as administrator or start the OpenSSH Authentication Agent service"}
      }
    } else {
      run-command ssh-add ["--apple-use-keychain" $key.key_path] --allow-failure | ignore
    }
  }
  if $key.key_present {
    run-command ssh-add [$key.key_path] --allow-failure --dry-run=$dry_run | ignore
  }
  {step: ssh-agent ok: true detail: "SSH agent is running"}
}

# Generate the default ed25519 SSH key when missing.
export def setup-ssh-key [
  config: record # Loaded configuration; setup.ssh.comment overrides the email comment.
  --dry-run # Show the generation without running it.
]: nothing -> record {
  let key = (ssh-key-status)
  if $key.key_present { return {step: ssh-key ok: true detail: $"key exists: ($key.key_path)"} }
  let configured_comment = (((($config.setup? | default {}).ssh? | default {}).comment? | default "") | str trim)
  let email = (git-config-get "user.email")
  let comment = if ($configured_comment | is-empty) { $email } else { $configured_comment }
  if $dry_run {
    run-command ssh-keygen ["-t" "ed25519" "-a" "100" "-C" $comment "-f" $key.key_path "-N" ""] --dry-run | ignore
    return {step: ssh-key ok: true detail: "would generate an ed25519 key"}
  }
  run-command ssh-keygen ["-t" "ed25519" "-a" "100" "-C" $comment "-f" $key.key_path "-N" ""] | ignore
  {step: ssh-key ok: true detail: $"generated: ($key.key_path)"}
}

# Upload the public key to GitHub and verify SSH login works.
export def setup-ssh-github [
  --dry-run # Show the upload without running it.
]: nothing -> record {
  let key = (ssh-key-status)
  if not $key.key_present { return {step: ssh-github ok: false detail: "no SSH key to upload"} }
  if not (command-exists gh) { return {step: ssh-github ok: false detail: "gh is not installed"} }
  if $dry_run {
    return {step: ssh-github ok: true detail: (if (github-has-ssh-key) { "key already on GitHub" } else { "would upload the key to GitHub" })}
  }
  if not (github-has-ssh-key) {
    let title = ($"reseed-(machine-name)" | str replace --regex '\s+' "_")
    let uploaded = (run-command gh ["ssh-key" "add" $key.pub_path "-t" $title] --allow-failure --capture)
    if $uploaded.exit_code != 0 {
      return {step: ssh-github ok: false detail: ($uploaded.stderr | str trim)}
    }
  }
  let test = (run-command ssh ["-o" "BatchMode=yes" "-o" "ConnectTimeout=10" "-o" "StrictHostKeyChecking=accept-new" "-T" "git@github.com"] --allow-failure --capture)
  let output = ($test.stdout + " " + $test.stderr)
  let ok = ($output | str contains "Hi ")
  {step: ssh-github ok: $ok detail: (if $ok { "SSH login to GitHub verified" } else { $"GitHub SSH login failed: ($test.stderr | str trim)" })}
}

# Append the public key line to a remote file via ssh stdin, so the key never
# needs quoting inside the remote shell command.
def ssh-append-pubkey [
  pub: string # Public key line to append.
  host: record # Host entry.
  remote_command: string # Command that appends stdin to the target file.
]: nothing -> record {
  let args = (ssh-install-args $host ["-o" "StrictHostKeyChecking=accept-new"])
  try {
    $pub | run-external ssh ...$args $remote_command | complete
  } catch {|error|
    {exit_code: 127 stdout: "" stderr: ($error.msg? | default ($error | to nuon))}
  }
}

# Turn SSH/remote-shell failures into stable, actionable diagnostics while
# retaining the original output and exit code for troubleshooting.
export def ssh-install-failure [host: record, result: record, target: string]: nothing -> string {
  let output = ($"(($result.stderr? | default '') | str trim) (($result.stdout? | default '') | str trim)" | str trim)
  let lower = ($output | str lowercase)
  let reason = if ($lower | str contains "permission denied (") or ($lower | str contains "permission denied, please try again") or ($lower | str contains "authentication failed") {
    "SSH authentication failed; enable password or keyboard-interactive login for the initial key installation"
  } else if ($lower | str contains "permission denied") or ($lower | str contains "access is denied") or ($lower | str contains "access to the path") or ($lower | str contains "unauthorizedaccess") {
    if $host.os == "windows" and $host.admin {
      "permission denied; remote installation is impossible without an elevated token for the Windows SSH account or another privileged session/tool that can update C:\\ProgramData\\ssh"
    } else {
      "permission denied while updating the remote key file"
    }
  } else if ($lower | str contains "connection refused") {
    "SSH connection refused; verify sshd and the configured port"
  } else if ($lower | str contains "timed out") or ($lower | str contains "timeout") {
    "SSH connection timed out; verify the host, network, firewall, and port"
  } else if ($lower | str contains "could not resolve hostname") or ($lower | str contains "name or service not known") {
    "SSH hostname could not be resolved"
  } else if ($lower | str contains "host key verification failed") {
    "SSH host-key verification failed; inspect and remove the stale known_hosts entry before retrying"
  } else {
    $"remote key installation exited with code ($result.exit_code? | default 127)"
  }
  let evidence = if ($output | is-empty) { "" } else { $"; remote output: ($output)" }
  $"($host.user)@($host.host): ($target) failed: ($reason)($evidence)"
}

# Install the public key on every configured host, and on the admin allow
# list when the host entry is marked admin.
export def setup-ssh-hosts [
  config: record # Loaded configuration; setup.ssh.hosts.
  --dry-run # Show the uploads without running them.
]: nothing -> record {
  let hosts = (setup-hosts $config)
  if ($hosts | is-empty) { return {step: ssh-hosts ok: true detail: "no hosts configured"} }
  let key = (ssh-key-status)
  if not $key.key_present { return {step: ssh-hosts ok: false detail: "no SSH key to install"} }
  let pub = (open --raw $key.pub_path | str trim)
  mut reports = []
  for host in $hosts {
    if (host-key-installed $host) {
      $reports = ($reports | append {ok: true detail: $"($host.user)@($host.host): passwordless login verified"})
      continue
    }
    if $dry_run {
      let target = if $host.os == "windows" and $host.admin { "Windows administrator key file" } else { "user key file" }
      $reports = ($reports | append {ok: true detail: $"($host.user)@($host.host): would install the key in the ($target) and verify passwordless login"})
      continue
    }

    # Administrators on Windows are matched by sshd's shared key-file rule;
    # their per-user authorized_keys file is ignored, so write the shared file
    # directly. Other platforms bootstrap the user file first.
    let direct_admin = ($host.os == "windows") and $host.admin
    let target = if $direct_admin { "Windows administrator key file" } else { "user key file" }
    let command = if $direct_admin { admin-keys-command windows } else { user-keys-command $host.os }
    let uploaded = (ssh-append-pubkey $pub $host $command)
    if $uploaded.exit_code != 0 {
      $reports = ($reports | append {ok: false detail: (ssh-install-failure $host $uploaded $target)})
      continue
    }

    mut details = [$"($host.user)@($host.host): installed key in ($target)"]
    if $host.admin and not $direct_admin {
      let added = (ssh-append-pubkey $pub $host (admin-keys-command $host.os))
      if $added.exit_code == 0 {
        $details = ($details | append $"administrator key file: (admin-key-path $host.os)")
      } else {
        $reports = ($reports | append {ok: false detail: (ssh-install-failure $host $added "administrator key file")})
        continue
      }
    }

    if not (host-key-installed $host) {
      $reports = ($reports | append {ok: false detail: $"($host.user)@($host.host): key files were updated, but passwordless login verification failed; inspect sshd logs and key-file ACLs"})
      continue
    }
    $details = ($details | append "passwordless login verified")
    $reports = ($reports | append {ok: true detail: ($details | str join "; ")})
  }
  {step: ssh-hosts ok: ($reports | all {|report| $report.ok }) detail: ($reports | get detail | str join "; ")}
}

# Add Host blocks for configured hosts to ~/.ssh/config, keeping existing
# entries.
export def setup-ssh-config [
  config: record # Loaded configuration; setup.ssh.hosts.
  --dry-run # Show the config edit without writing it.
]: nothing -> record {
  let hosts = (setup-hosts $config)
  if ($hosts | is-empty) { return {step: ssh-config ok: true detail: "no hosts configured"} }
  let path = (ssh-config-path)
  let existing = if ($path | path exists) { open --raw $path } else { "" }
  let merged = (ssh-config-merge $existing $hosts)
  if ($merged == ($existing | str trim)) {
    return {step: ssh-config ok: true detail: "hosts already in ssh config"}
  }
  if not $dry_run {
    mkdir ($path | path dirname)
    $merged | save --force $path
  }
  {step: ssh-config ok: true detail: (if $dry_run { "would update ~/.ssh/config" } else { "updated ~/.ssh/config" })}
}

# Verify passwordless login to every configured host.
export def setup-ssh-test [
  config: record # Loaded configuration; setup.ssh.hosts.
  --dry-run # Show the probes without running them.
]: nothing -> record {
  let hosts = (setup-hosts $config)
  if ($hosts | is-empty) { return {step: ssh-test ok: true detail: "no hosts configured"} }
  mut reports = []
  for host in $hosts {
    if $dry_run {
      $reports = ($reports | append $"($host.user)@($host.host): would probe")
    } else if (host-key-installed $host) {
      $reports = ($reports | append $"($host.user)@($host.host): connected")
    } else {
      $reports = ($reports | append $"($host.user)@($host.host): no passwordless login")
    }
  }
  {step: ssh-test ok: ($reports | all {|report| not ($report | str contains "no passwordless") }) detail: ($reports | str join "; ")}
}
