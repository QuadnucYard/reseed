# SSH setup steps: the agent, the default key, GitHub registration, remote
# host key installation (including the admin allow list), ssh config
# entries, and connectivity tests.

use ../core.nu [command-exists detect-os expand-home run-command]
use ./shared.nu [machine-name ssh-agent-running ssh-key-status]
use ./git.nu [git-config-get]

# Whether the local public SSH key is already registered on GitHub.
export def github-has-ssh-key []: nothing -> bool {
  if not (command-exists gh) { return false }
  let key = (ssh-key-status)
  if not $key.key_present { return false }
  let local = (open --raw $key.pub_path | str trim)
  let listing = (run-command gh ["ssh-key" "list" "--json" "key"] --allow-failure --quiet)
  if $listing.exit_code != 0 { return false }
  let keys = (try { $listing.stdout | from json | get key } catch { return false })
  ($keys | any {|remote| ($remote | str trim) == $local })
}

# Normalized configured host entries.
def setup-hosts [config: record]: nothing -> list<record> {
  let hosts = ((($config.setup? | default {}).ssh? | default {}).hosts? | default [])
  $hosts | each {|host| {
    user: ($host.user? | default "")
    host: ($host.host? | default "")
    port: ($host.port? | default 22)
    admin: ($host.admin? | default false)
    os: ($host.os? | default "unix")
  }}
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

# Whether passwordless login to the host already works.
def host-key-installed [host: record]: nothing -> bool {
  let probe = (run-command ssh ((ssh-connect-args $host) | append "exit 0") --allow-failure --quiet)
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
  (setup-hosts $config | all {|host| ($existing | lines | any {|line| ($line | str trim) == $"Host ($host.host)" }) })
}

# Generated Host block for one host entry.
def ssh-config-block [host: record]: nothing -> string {
  let port = ($host.port? | default 22)
  [$"Host ($host.host)" $"HostName ($host.host)" $"User ($host.user)"]
    | append (if $port == 22 { [] } else { [$"Port ($port)"] })
    | str join "\n"
}

# Merge generated Host blocks into an existing ssh config, keeping the Host
# blocks that are already present.
export def ssh-config-merge [existing: string, hosts: list<record>]: nothing -> string {
  let lines = ($existing | lines)
  mut parts = [$existing]
  for host in $hosts {
    if ($lines | any {|line| ($line | str trim) == $"Host ($host.host)" }) { continue }
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

# POSIX command that appends stdin to the account's authorized_keys.
def authorized-keys-command []: nothing -> string {
  "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
}

# Command that appends a public key line to the admin allow list on the host.
export def admin-keys-command [os: string, key: string]: nothing -> string {
  if $os == "windows" {
    let path = (admin-key-path $os)
    $"powershell -NoProfile -Command \"Add-Content -Path '($path)' -Value '($key)'\""
  } else {
    $"mkdir -p (admin-key-path $os | path dirname) && chmod 700 (admin-key-path $os | path dirname) && echo '($key)' >> (admin-key-path $os) && chmod 600 (admin-key-path $os)"
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
  let configured_comment = ($config.setup.ssh.comment? | default "" | str trim)
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
    let uploaded = (run-command gh ["ssh-key" "add" $key.pub_path "-t" $title] --allow-failure)
    if $uploaded.exit_code != 0 {
      return {step: ssh-github ok: false detail: ($uploaded.stderr | str trim)}
    }
  }
  let test = (run-command ssh ["-o" "BatchMode=yes" "-o" "ConnectTimeout=10" "-o" "StrictHostKeyChecking=accept-new" "-T" "git@github.com"] --allow-failure)
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
  let args = (ssh-connect-args $host ["-o" "StrictHostKeyChecking=accept-new"])
  try {
    $pub | run-external ssh ...$args $remote_command | complete
  } catch {|error|
    {exit_code: 127 stdout: "" stderr: ($error.msg? | default ($error | to nuon))}
  }
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
      $reports = ($reports | append $"($host.user)@($host.host): key present")
      continue
    }
    if $dry_run {
      $reports = ($reports | append $"($host.user)@($host.host): would upload the key")
      continue
    }
    let uploaded = (ssh-append-pubkey $pub $host (authorized-keys-command))
    if $uploaded.exit_code != 0 {
      $reports = ($reports | append $"($host.user)@($host.host): upload failed: ($uploaded.stderr | str trim)")
      continue
    }
    $reports = ($reports | append $"($host.user)@($host.host): key uploaded")
    if $host.admin {
      let added = (run-command ssh ((ssh-connect-args $host) | append (admin-keys-command $host.os $pub)) --allow-failure)
      if $added.exit_code == 0 {
        $reports = ($reports | append $"admin list: (admin-key-path $host.os)")
      } else {
        $reports = ($reports | append $"admin list: failed: ($added.stderr | str trim)")
      }
    }
  }
  {step: ssh-hosts ok: ($reports | all {|report| not ($report | str contains "failed") }) detail: ($reports | str join "; ")}
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
