# Repository provider detection and transport checks for the protocol-aware
# `setup gh` purpose. Descriptors keep provider knowledge data-driven so other
# Git hosts can add setup adapters without touching the step dispatcher.

use ../core.nu [command-exists run-command]
use ./git.nu [git-config-get]

# Provider name for a host, or "generic". Matching requires the exact hostname
# or a subdomain on a label boundary, so a lookalike like "evilgithub.com" is
# never treated as GitHub.
def provider-for [host: string]: nothing -> string {
  if ($host == "github.com") or ($host | str ends-with ".github.com") { "github" } else if ($host == "gitlab.com") or ($host | str ends-with ".gitlab.com") { "gitlab" } else { "generic" }
}

# Parse a repository URL into its transport, host, path, and provider. Handles
# scp-style (git@host:org/repo), ssh://, https://, http://, and git:// URLs.
export def parse-repo-url [url: string]: nothing -> record {
  if ($url =~ '^[^@/]+@[^:]+:') {
    # scp-like git@host:org/repo[.git]
    let user = ($url | split row '@' | get 0)
    let rest = ($url | str substring (($user | str length) + 1)..)
    let host = ($rest | split row ':' | get 0)
    let path = ($rest | str substring (($host | str length) + 1)..)
    return {transport: ssh host: $host path: $path provider: (provider-for $host)}
  }
  if ($url =~ '^[a-z][a-z0-9+.-]*://') {
    let scheme = ($url | str replace --regex '^([a-z][a-z0-9+.-]*)://.*' '$1')
    let rest = ($url | str substring (($scheme | str length) + 3)..)
    let host_raw = ($rest | split row '/' | get 0)
    let host = ($host_raw | str replace --regex '^[^@]*@' "")
    let path = ($rest | str substring (($host_raw | str length) + 1)..)
    let transport = match $scheme { ssh => "ssh" https => "https" http => "https" _ => "git" }
    return {transport: $transport host: $host path: $path provider: (provider-for $host)}
  }
  {transport: https host: "" path: $url provider: "generic"}
}

# Data-driven setup descriptor for a provider: whether the gh CLI owns uploads,
# the SSH host used for key verification, and the transport check to run.
export def provider-descriptor [provider: string]: nothing -> record {
  match $provider {
    github => {name: github host: "github.com" ssh_host: "github.com" gh_cli: true}
    gitlab => {name: gitlab host: "gitlab.com" ssh_host: "gitlab.com" gh_cli: false}
    _ => {name: generic host: "" ssh_host: "" gh_cli: false}
  }
}

# Probe repository reachability over its transport with a bounded, read-only
# ls-remote. HTTPS transfers are capped by low-speed settings, SSH connections
# by batch mode plus a connect timeout, and a real process deadline kills the
# probe if it stalls before any transfer begins. Local paths skip the deadline.
export def repo-transport-check [url: string]: nothing -> record {
  if ($url | str trim | is-empty) { return {ok: false detail: "no repository URL configured"} }
  let ssh = ($env.GIT_SSH_COMMAND? | default "ssh -o BatchMode=yes -o ConnectTimeout=10")
  let remote = (($url | str contains "://") or ($url | str starts-with "git@") or ($url | str starts-with "ssh:"))
  let probe = (run-command git [
    "-c" "http.lowSpeedLimit=1" "-c" "http.lowSpeedTime=15"
    "ls-remote" "--heads" $url
  ] --allow-failure --quiet --capture --environment={GIT_SSH_COMMAND: $ssh} --timeout=(if $remote { 20 } else { 0 }))
  if $probe.exit_code == 0 {
    {ok: true detail: "repository reachable"}
  } else {
    {ok: false detail: ($probe.stderr | str trim)}
  }
}

# Configure Git to authenticate repository access through the gh CLI
# (`gh auth setup-git` is idempotent and installs its credential helper).
export def setup-gh-credential-helper [
  --dry-run # Show the configuration without running it.
]: nothing -> record {
  if not (command-exists gh) {
    return {step: gh-credential-helper ok: false detail: "gh is not installed"}
  }
  let current = (git-config-get "credential.helper")
  if ($current | str contains "gh") {
    return {step: gh-credential-helper ok: true detail: "Git already uses the gh credential helper"}
  }
  if $dry_run {
    return {step: gh-credential-helper ok: true detail: "would run 'gh auth setup-git' to install the gh credential helper"}
  }
  let configured = (run-command gh ["auth" "setup-git"] --allow-failure --quiet --capture)
  if $configured.exit_code != 0 {
    return {step: gh-credential-helper ok: false detail: ($configured.stderr | str trim)}
  }
  {step: gh-credential-helper ok: true detail: "Git now uses the gh credential helper"}
}

# Probe the private state repository over its configured transport so HTTPS
# (gh credentials) and SSH (key) setup are verified before recovery.
export def setup-gh-repo-probe [
  url: string # Private state repository URL.
  --dry-run # Show the probe without running it.
]: nothing -> record {
  if ($url | str trim | is-empty) {
    return {step: gh-repo-probe ok: false detail: "no private state repository URL is configured"}
  }
  if $dry_run {
    return {step: gh-repo-probe ok: true detail: "would probe repository reachability over its transport"}
  }
  let check = (repo-transport-check $url)
  if $check.ok {
    {step: gh-repo-probe ok: true detail: "private state repository reachable"}
  } else {
    {step: gh-repo-probe ok: false detail: $check.detail}
  }
}
