# Tests for the guided setup module: purpose planning, feature gating,
# output parsing, and generated command/content builders.

use std assert
use ./helpers.nu ["assert eq" "assert ne"]
use ../lib/setup.nu [admin-key-path admin-keys-command gpg-batch-file jj-signing-behaviors normalize-ssh-host parse-gh-scopes parse-gpg-secret-ids setup-plan setup-hosts ssh-config-merge ssh-host-duplicate ssh-hosts-empty ssh-hosts-source-update ssh-install-args ssh-install-failure ssh-verification-args user-keys-command windows-admin-keys-script windows-user-keys-script]

# Purpose planning: step selection, dependency closure, ordering, and
# deduplication of shared steps.
def test-setup-plans [] {
  let expected_all = [
    jj-prereq identity gh-auth ssh-key ssh-agent ssh-github ssh-hosts
    ssh-config ssh-test gpg-prereq gpg-key gpg-github gpg-git gpg-jj gpg-verify
  ]
  assert eq (setup-plan all | get step) $expected_all "all purpose step order"
  assert eq (setup-plan all | get order) (1..15 | each {|i| $i}) "all purpose ordering is numbered"

  assert eq (setup-plan identity | get step) [jj-prereq identity] "identity purpose pulls the jj prerequisite"
  assert eq (setup-plan ssh-local | get step) [jj-prereq identity ssh-key ssh-agent] "ssh-local purpose plan"
  assert eq (setup-plan ssh-remote | get step) [jj-prereq identity ssh-key ssh-hosts ssh-config] "ssh-remote purpose plan"
  assert eq (setup-plan ssh | get step) [jj-prereq identity ssh-key ssh-agent ssh-hosts ssh-config ssh-test] "ssh purpose plan"
  assert eq (setup-plan gh | get step) [jj-prereq identity gh-auth ssh-key ssh-github] "gh purpose plan"
  assert eq (setup-plan gpg | get step) [jj-prereq identity gh-auth gpg-prereq gpg-key gpg-github gpg-git gpg-jj gpg-verify] "gpg purpose plan"
  assert eq ($expected_all | where {|step| $step == ssh-key } | length) 1 "shared steps appear once"
}

# The gh purpose is routed by provider and transport: GitHub URLs use the gh
# CLI (SSH: key generation/upload; HTTPS: auth, credential helper, probe),
# while other Git hosts skip gh and run the generic transport check.
def test-setup-gh-protocol-plans [] {
  assert eq (setup-plan gh --repo-url "git@github.com:org/state.git" | get step) [jj-prereq identity gh-auth ssh-key ssh-github] "github SSH URLs use the SSH key flow"
  assert eq (setup-plan gh --repo-url "ssh://git@github.com/org/state.git" | get step) [jj-prereq identity gh-auth ssh-key ssh-github] "ssh:// URLs use the SSH key flow"
  assert eq (setup-plan gh --repo-url "https://github.com/org/state.git" | get step) [jj-prereq identity gh-auth gh-credential-helper gh-repo-probe] "github HTTPS URLs drive gh auth and credential-helper setup"
  assert eq (setup-plan gh --repo-url "git@gitlab.com:org/state.git" | get step) [jj-prereq identity ssh-key gh-repo-probe] "gitlab SSH URLs skip gh and probe generically"
  assert eq (setup-plan gh --repo-url "https://evilgithub.com/org/state.git" | get step) [jj-prereq identity gh-repo-probe] "a lookalike github.com host is never treated as GitHub"
  assert eq (setup-plan gh --repo-url "https://gitlab.com.example.com/org/state.git" | get step) [jj-prereq identity gh-repo-probe] "a suffixed gitlab.com host is never treated as GitLab"
  assert eq (setup-plan gh --repo-url "https://gitlab.com/org/state.git" | get step) [jj-prereq identity gh-repo-probe] "gitlab HTTPS URLs skip gh entirely"
  assert eq (setup-plan gh --repo-url "https://git.example.com/org/state.git" | get step) [jj-prereq identity gh-repo-probe] "generic HTTPS hosts skip gh entirely"
  assert eq (setup-plan gh --repo-url "git@git.example.com:org/state.git" | get step) [jj-prereq identity ssh-key gh-repo-probe] "generic SSH hosts generate a key and probe"
  assert eq (setup-plan gh --repo-url "" | get step) [jj-prereq identity gh-auth ssh-key ssh-github] "gh without a repository URL keeps the default flow"

  # The all and gpg purposes are provider-aware too: a default setup on a
  # non-GitHub host never authenticates with or uploads to GitHub.
  let gitlab_all = (setup-plan all --repo-url "https://gitlab.com/org/state.git" | get step)
  assert ($gitlab_all | where {|step| $step in [gh-auth ssh-github gpg-github gh-credential-helper] } | is-empty) "all on GitLab skips GitHub uploads"
  assert ("gh-repo-probe" in $gitlab_all) "all on GitLab probes the repository generically"
  let generic_all = (setup-plan all --repo-url "git@git.example.com:org/state.git" | get step)
  assert ($generic_all | where {|step| $step in [gh-auth ssh-github gpg-github] } | is-empty) "all on a generic host skips GitHub uploads"
  let gitlab_gpg = (setup-plan gpg --repo-url "https://gitlab.com/org/state.git" | get step)
  assert ("gpg-github" not-in $gitlab_gpg) "gpg on GitLab skips the GitHub GPG upload"
  let github_all = (setup-plan all --repo-url "https://github.com/org/state.git" | get step)
  assert (("gh-auth" in $github_all) and ("gh-credential-helper" in $github_all) and ("gpg-github" in $github_all)) "all on GitHub HTTPS keeps gh auth, the credential helper, and the GPG upload"
  let github_ssh_all = (setup-plan all --repo-url "git@github.com:org/state.git" | get step)
  assert ("ssh-github" in $github_ssh_all) "all on GitHub SSH keeps the key upload"
}

# Feature gating: disabling jj or GPG removes the gated steps from every
# purpose, keeping the remaining order stable.
def test-setup-feature-gating [] {
  let no_gpg = (setup-plan all --gpg=false | get step)
  assert ($no_gpg | where {|step| $step | str starts-with "gpg" } | is-empty) "gpg steps are gated off"
  assert eq $no_gpg [jj-prereq identity gh-auth ssh-key ssh-agent ssh-github ssh-hosts ssh-config ssh-test] "all without gpg keeps ssh and gh steps"

  let no_jj = (setup-plan all --jj=false | get step)
  assert ($no_jj | where {|step| $step in [jj-prereq gpg-jj] } | is-empty) "jj steps are gated off"
  assert eq $no_jj [identity gh-auth ssh-key ssh-agent ssh-github ssh-hosts ssh-config ssh-test gpg-prereq gpg-key gpg-github gpg-git gpg-verify] "all without jj keeps the remaining order"

  assert eq (setup-plan gpg --jj=false | get step) [identity gh-auth gpg-prereq gpg-key gpg-github gpg-git gpg-verify] "gpg purpose without jj"
  assert eq (setup-plan gpg --gpg=false | get step) [jj-prereq identity gh-auth] "gpg purpose without gpg keeps shared prerequisites"
  assert eq (setup-plan identity --jj=false | get step) [identity] "identity without jj keeps only git"
}

# gh auth status scope parsing.
def test-gh-scope-parsing [] {
  assert eq (parse-gh-scopes "- Token scopes: 'admin:public_key', 'gist', 'read:org', 'repo'") [admin:public_key gist read:org repo] "gh scope parsing"
  assert eq (parse-gh-scopes "nothing to see here") [] "gh scope parsing without a scopes line"
  assert eq (parse-gh-scopes "") [] "gh scope parsing of empty output"
}

# GPG --with-colons secret key id parsing.
def test-gpg-colons-parsing [] {
  let sample = [
    "sec:u:255:22:966D6BB80ACFC36B:2024-01-01T00:00:00Z:::scESC:::+::23::0:"
    "fpr:::::::::5B5D7B0F5A966D6BB80ACFC36B:"
    "uid:u::::2024-01-01T00:00:00Z::ABCDEF1234567890::Test User <test@example.com>::::::::::0:"
    "sec:-:3072:1:0123456789ABCDEF:2024-01-02T00:00:00Z:::scESC:::+::23::0:"
    "pub:u:255:22:966D6BB80ACFC36B:2024-01-01T00:00:00Z:::scESC:::+::23::0:"
  ] | str join "\n"
  assert eq (parse-gpg-secret-ids $sample) ["966D6BB80ACFC36B" "0123456789ABCDEF"] "gpg secret key ids from colons output"
  assert eq (parse-gpg-secret-ids "pub:u:255:22:966D6BB80ACFC36B:::") [] "gpg colons parsing ignores public keys"
  assert eq (parse-gpg-secret-ids "") [] "gpg colons parsing of empty output"
}

# SSH config Host block generation and idempotent merging.
def test-ssh-config-merge [] {
  assert eq (ssh-config-merge "" [{user: alice host: example.com port: 22 admin: false os: unix}]) "Host example.com\nHostName example.com\nUser alice" "ssh config block generation"

  let ported = (ssh-config-merge "" [{user: alice host: example.com port: 2222}])
  let port_lines = ($ported | lines | where {|line| ($line | str trim) | str starts-with "Port " })
  assert eq $port_lines ["Port 2222"] "ssh config block includes non-default ports"

  let existing = "Host existing\n  HostName existing.example\n  User bob"
  let merged = (ssh-config-merge $existing [{user: alice host: example.com}])
  assert ($merged | str contains "Host example.com") "ssh config merge appends new hosts"
  assert ($merged | str contains "Host existing") "ssh config merge keeps existing hosts"
  let twice = (ssh-config-merge $merged [{user: alice host: example.com}])
  assert eq $twice $merged "ssh config merge is idempotent"
}

def test-ssh-host-helpers [] {
  let empty = {setup: {ssh: {hosts: []}}}
  assert (ssh-hosts-empty $empty) "empty SSH host configuration is detected"
  let candidate = (normalize-ssh-host " alice " "Example.COM" 2222 true windows)
  assert eq $candidate {user: alice host: Example.COM port: 2222 admin: true os: windows} "SSH host normalization"
  assert (ssh-host-duplicate {setup: {ssh: {hosts: [{user: bob host: example.com port: 2222}]}}} $candidate) "duplicate host and port detection ignores case"
  assert (not (ssh-host-duplicate {setup: {ssh: {hosts: [{user: bob host: example.com port: 22}]}}} $candidate)) "different SSH ports are allowed"

  let source = "{\n # preserve this comment\n setup: {\n  ssh: {\n   # preserve host docs\n   hosts: []\n  }\n }\n}\n"
  let updated = (ssh-hosts-source-update $source ($source | from nuon) [(normalize-ssh-host alice example.com)])
  assert ($updated | str contains "preserve this comment") "source update preserves surrounding comments"
  assert ($updated | str contains "host: \"example.com\"") "source update writes the new host"
  assert eq (($updated | from nuon).setup.ssh.hosts.0.host) example.com "source update remains valid NUON"

  let minimal = "{schema: 1}\n"
  let expanded = (ssh-hosts-source-update $minimal ($minimal | from nuon) [(normalize-ssh-host alice example.com)])
  assert eq (($expanded | from nuon).setup.ssh.hosts.0.user) alice "source update creates missing setup sections"
}

# Admin allow list paths and upload commands per host operating system.
def test-admin-key-handling [] {
  assert eq (admin-key-path windows) "C:\\ProgramData\\ssh\\administrators_authorized_keys" "windows admin key path"
  assert eq (admin-key-path macos) "/var/root/.ssh/authorized_keys" "macos admin key path"
  assert eq (admin-key-path unix) "/root/.ssh/authorized_keys" "unix admin key path"

  let unix = (admin-keys-command unix)
  assert ($unix | str contains "/root/.ssh/authorized_keys") "unix admin command targets the allow list"
  assert ($unix | str contains "key=$(cat)") "unix admin command reads the key from stdin"
  let windows = (admin-keys-command windows)
  assert ($windows | str contains "-EncodedCommand") "Windows admin command is independent of the configured sshd shell"
  let windows_admin_script = (windows-admin-keys-script)
  assert ($windows_admin_script | str contains "administrators_authorized_keys") "windows admin command targets the allow list"
  assert ($windows_admin_script | str contains "icacls.exe") "windows admin command restricts the allow-list ACL"
  assert ($windows_admin_script | str contains "S-1-5-32-544:F") "windows admin ACL grants the built-in Administrators group independent of locale"
  assert ($windows_admin_script | str contains "S-1-5-18:F") "windows admin ACL grants SYSTEM"
  assert ($windows_admin_script | str contains "AppendAllText") "windows admin command writes UTF-8 without a BOM"

  let windows_user = (user-keys-command windows)
  assert ($windows_user | str contains "-EncodedCommand") "Windows user keys use shell-independent encoded PowerShell"
  let windows_user_script = (windows-user-keys-script)
  assert ($windows_user_script | str contains "[Console]::In.ReadToEnd") "Windows user key reads the public key from stdin"
  assert ($windows_user_script | str contains "WindowsIdentity]::GetCurrent().User.Value") "Windows user ACL uses the current account SID"
  let unix_user = (user-keys-command unix)
  assert ($unix_user | str contains "key=$(cat)") "Unix user key reads the public key from stdin"
  assert ($unix_user | str contains "grep -qxF") "Unix user key installation is idempotent"
}

def test-ssh-install-errors [] {
  let admin = {user: Administrator host: win.example port: 22 admin: true os: windows}
  let install_args = (ssh-install-args $admin)
  assert ("BatchMode=no" in $install_args) "initial SSH key installation permits interactive authentication"
  assert ("BatchMode=yes" not-in $install_args) "initial SSH key installation is not forced into batch mode"
  assert ("NumberOfPasswordPrompts=3" in $install_args) "initial SSH key installation bounds password retries"
  let verification_args = (ssh-verification-args $admin "C:\\keys\\id_ed25519")
  assert ("BatchMode=yes" in $verification_args) "SSH key verification is noninteractive"
  assert ("IdentitiesOnly=yes" in $verification_args) "SSH key verification excludes unrelated identities"
  assert ("C:\\keys\\id_ed25519" in $verification_args) "SSH key verification uses the managed identity"
  let auth = (ssh-install-failure $admin {exit_code: 255 stdout: "" stderr: "Permission denied (publickey,password)."} "Windows administrator key file")
  assert ($auth | str contains "authentication failed") "SSH authentication failures are classified"
  let acl = (ssh-install-failure $admin {exit_code: 1 stdout: "" stderr: "Access is denied."} "Windows administrator key file")
  assert ($acl | str contains "elevated token") "Windows administrator ACL failures explain elevation"
  assert ($acl | str contains "Access is denied") "remote failure evidence is retained"
  let timeout = (ssh-install-failure $admin {exit_code: 255 stdout: "" stderr: "Connection timed out"} "Windows administrator key file")
  assert ($timeout | str contains "network, firewall, and port") "SSH timeouts have network guidance"
}

# GPG batch key generation content.
def test-gpg-batch-file [] {
  let batch = (gpg-batch-file "Test User" "test@example.com")
  assert ($batch | str contains "%no-protection") "gpg batch runs without a passphrase"
  assert ($batch | str contains "Key-Type: ed25519") "gpg batch uses ed25519"
  assert ($batch | str contains "Key-Usage: sign") "gpg batch is a signing key"
  assert ($batch | str contains "Name-Real: Test User") "gpg batch carries the real name"
  assert ($batch | str contains "Name-Email: test@example.com") "gpg batch carries the email"
  assert ($batch | str contains "Expire-Date: 0") "gpg batch never expires"
}

# jj signing behavior choices offered by the signing step.
def test-jj-signing-behaviors [] {
  assert eq (jj-signing-behaviors) [drop keep own force] "jj signing behavior choices"
}

def main [] {
  test-setup-plans
  test-setup-gh-protocol-plans
  test-setup-feature-gating
  test-gh-scope-parsing
  test-gpg-colons-parsing
  test-ssh-config-merge
  test-ssh-host-helpers
  test-admin-key-handling
  test-ssh-install-errors
  test-gpg-batch-file
  test-jj-signing-behaviors

  print "All Reseed setup tests passed"
}
