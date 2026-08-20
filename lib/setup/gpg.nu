# GPG signing setup steps: GnuPG installation, key generation, GitHub
# registration, and a signed-commit verification. Git and jj signing
# configuration live in setup/git.nu and setup/jj.nu.

use ../core.nu [command-exists detect-os run-command]
use ./shared.nu [gpg-secret-key-id]
use ./git.nu [git-config-get]

# Whether the local GPG signing key is already registered on GitHub.
export def github-has-gpg-key []: nothing -> bool {
  if not (command-exists gh) { return false }
  let id = (gpg-secret-key-id)
  if ($id | is-empty) { return false }
  let listing = (run-command gh ["gpg-key" "list" "--json" "key_id"] --allow-failure --quiet --capture)
  if $listing.exit_code != 0 { return false }
  let ids = (try { $listing.stdout | from json | get key_id } catch { return false })
  ($ids | any {|remote| ($remote | str trim) == $id })
}

# Ensure GnuPG is installed, installing it through the platform package
# manager when missing.
export def setup-gpg-prereq [
  --dry-run # Show the install without running it.
]: nothing -> record {
  if (command-exists gpg) { return {step: gpg-prereq ok: true detail: "GnuPG is installed"} }
  if $dry_run { return {step: gpg-prereq ok: true detail: "would install GnuPG"} }
  let installed = (try {
    if (detect-os) == "windows" {
      run-command winget ["install" "-e" "--id" "GnuPG.GnuPG" "--accept-package-agreements" "--accept-source-agreements"] --allow-failure
    } else {
      run-command brew ["install" "gnupg"] --allow-failure
    }
  } catch {|error|
    {exit_code: 127 stdout: "" stderr: ($error.msg? | default ($error | to nuon))}
  })
  if (command-exists gpg) {
    {step: gpg-prereq ok: true detail: "GnuPG installed"}
  } else {
    let stderr = ($installed.stderr | str trim)
    let detail = if ($stderr | is-empty) {
      "GnuPG install failed; install it manually and rerun"
    } else {
      $"GnuPG install failed: ($stderr); install it manually and rerun"
    }
    {step: gpg-prereq ok: false detail: $detail}
  }
}

# Batch file content for an ed25519 signing key without a passphrase.
export def gpg-batch-file [name: string, email: string]: nothing -> string {
  [
    "%no-protection"
    "Key-Type: ed25519"
    "Key-Usage: sign"
    $"Name-Real: ($name)"
    $"Name-Email: ($email)"
    "Expire-Date: 0"
    "%commit"
  ] | str join "\n"
}

# Generate an ed25519 signing key (no passphrase) when no secret key exists.
export def setup-gpg-key [
  --dry-run # Show the generation without running it.
]: nothing -> record {
  let key_id = (gpg-secret-key-id)
  if ($key_id | is-not-empty) { return {step: gpg-key ok: true detail: $"signing key exists: ($key_id)"} }
  if $dry_run { return {step: gpg-key ok: true detail: "would generate an ed25519 signing key"} }
  let name = (git-config-get "user.name")
  let email = (git-config-get "user.email")
  if ($name | is-empty) or ($email | is-empty) {
    return {step: gpg-key ok: false detail: "the Git identity is required for the GPG key"}
  }
  let batch = (mktemp)
  gpg-batch-file $name $email | save --force $batch
  let generated = (run-command gpg ["--batch" "--generate-key" ($batch | into string)] --allow-failure)
  rm --force $batch
  if $generated.exit_code != 0 {
    let stderr = ($generated.stderr | str trim)
    let detail = if ($stderr | is-empty) { "key generation failed" } else { $stderr }
    return {step: gpg-key ok: false detail: $detail}
  }
  let new_id = (gpg-secret-key-id)
  if ($new_id | is-empty) {
    return {step: gpg-key ok: false detail: "key generation did not produce a secret key"}
  }
  {step: gpg-key ok: true detail: $"generated signing key: ($new_id)"}
}

# Upload the armored public key to GitHub, refreshing the write:gpg_key scope
# on authorization failure.
export def setup-gpg-github [
  --dry-run # Show the upload without running it.
]: nothing -> record {
  if $dry_run {
    return {step: gpg-github ok: true detail: (if (github-has-gpg-key) { "key already on GitHub" } else { "would generate and upload the GPG key" })}
  }
  let key_id = (gpg-secret-key-id)
  if ($key_id | is-empty) { return {step: gpg-github ok: false detail: "no GPG signing key to upload"} }
  if not (command-exists gh) { return {step: gpg-github ok: false detail: "gh is not installed"} }
  if (github-has-gpg-key) { return {step: gpg-github ok: true detail: "key already on GitHub"} }
  let armor = (mktemp)
  run-command gpg ["--armor" "--export" $key_id] --capture | get stdout | save --force $armor
  let uploaded = (run-command gh ["gpg-key" "add" ($armor | into string)] --allow-failure --capture)
  if $uploaded.exit_code != 0 and (($uploaded.stderr | str contains "401") or ($uploaded.stderr | str contains "403")) {
    run-command gh ["auth" "refresh" "-h" "github.com" "-s" "write:gpg_key"] | ignore
    let retry = (run-command gh ["gpg-key" "add" ($armor | into string)] --allow-failure --capture)
    rm --force $armor
    if $retry.exit_code != 0 {
      return {step: gpg-github ok: false detail: ($retry.stderr | str trim)}
    }
    return {step: gpg-github ok: true detail: "uploaded after refreshing the write:gpg_key scope"}
  }
  rm --force $armor
  if $uploaded.exit_code != 0 {
    return {step: gpg-github ok: false detail: ($uploaded.stderr | str trim)}
  }
  {step: gpg-github ok: true detail: "uploaded to GitHub"}
}

# Verify Git can create a signed commit with the configured key.
export def setup-gpg-verify [
  --dry-run # Report the verification instead of running it.
]: nothing -> record {
  if $dry_run { return {step: gpg-verify ok: true detail: "would verify a signed commit"} }
  let key_id = (gpg-secret-key-id)
  if ($key_id | is-empty) {
    return {step: gpg-verify ok: false detail: "no GPG secret key available for signing"}
  }
  let scratch = (mktemp --directory)
  run-command git ["-C" ($scratch | into string) "init" "-b" "main"] --quiet | ignore
  let name = (git-config-get "user.name")
  let email = (git-config-get "user.email")
  let committed = (run-command git [
    "-C" ($scratch | into string)
    "-c" $"user.name=($name)"
    "-c" $"user.email=($email)"
    "-c" $"user.signingkey=($key_id)"
    "commit" "--allow-empty" "-S" "-m" "reseed signature verification"
  ] --allow-failure --quiet --capture)
  if $committed.exit_code != 0 {
    rm --recursive --force $scratch
    return {step: gpg-verify ok: false detail: ($committed.stderr | str trim)}
  }
  let verified = (run-command git ["-C" ($scratch | into string) "log" "-1" "--format=%G?"] --quiet --capture)
  rm --recursive --force $scratch
  let status = ($verified.stdout | str trim)
  if $status != "G" {
    return {step: gpg-verify ok: false detail: $"signature status: ($status)"}
  }
  {step: gpg-verify ok: true detail: "signed commit verified"}
}
