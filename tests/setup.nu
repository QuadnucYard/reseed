# Tests for the guided setup module: purpose planning, feature gating,
# output parsing, and generated command/content builders.

use std assert
use ./helpers.nu ["assert eq" "assert ne"]
use ../lib/setup.nu [admin-key-path admin-keys-command gpg-batch-file jj-signing-behaviors parse-gh-scopes parse-gpg-secret-ids setup-plan ssh-config-merge]

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

# Admin allow list paths and upload commands per host operating system.
def test-admin-key-handling [] {
  assert eq (admin-key-path windows) "C:\\ProgramData\\ssh\\administrators_authorized_keys" "windows admin key path"
  assert eq (admin-key-path macos) "/var/root/.ssh/authorized_keys" "macos admin key path"
  assert eq (admin-key-path unix) "/root/.ssh/authorized_keys" "unix admin key path"

  let unix = (admin-keys-command unix "ssh-ed25519 AAAAB3 test@example")
  assert ($unix | str contains "/root/.ssh/authorized_keys") "unix admin command targets the allow list"
  assert ($unix | str contains "ssh-ed25519 AAAAB3") "unix admin command embeds the key"
  let windows = (admin-keys-command windows "ssh-ed25519 AAAAB3 test@example")
  assert ($windows | str contains "administrators_authorized_keys") "windows admin command targets the allow list"
  assert ($windows | str contains "Add-Content") "windows admin command uses PowerShell"
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
  test-setup-feature-gating
  test-gh-scope-parsing
  test-gpg-colons-parsing
  test-ssh-config-merge
  test-admin-key-handling
  test-gpg-batch-file
  test-jj-signing-behaviors

  print "All Reseed setup tests passed"
}
