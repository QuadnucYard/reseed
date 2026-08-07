# Git-specific setup: configuration access, identity detection, the identity
# half of the identity step, and commit-signing configuration.

use ../core.nu [command-exists fail run-command]
use ./shared.nu [first-external-path gpg-secret-key-id]

# Git global configuration value, or "" when unset.
export def git-config-get [key: string]: nothing -> string {
  if not (command-exists git) { return "" }
  let value = (run-command git ["config" "--global" "--get" $key] --allow-failure --quiet)
  if $value.exit_code != 0 { "" } else { $value.stdout | str trim }
}

# Whether the git identity (user.name and user.email) is configured.
export def identity-present []: nothing -> bool {
  not ((git-config-get "user.name") | is-empty) and not ((git-config-get "user.email") | is-empty)
}

# Whether git is configured to sign commits with a key.
export def git-signing-configured []: nothing -> bool {
  not ((git-config-get "user.signingkey") | is-empty) and (git-config-get "commit.gpgsign") == "true"
}

# Prompt for and apply the Git user identity, returning the resolved name and
# email for other steps to reuse.
export def setup-git-identity [
  --yes # Apply defaults; fail when the identity is missing.
  --dry-run # Show the config commands without running them.
]: nothing -> record {
  let existing_name = (git-config-get "user.name")
  let existing_email = (git-config-get "user.email")
  let name = if ($existing_name | str trim | is-empty) {
    if $yes { fail "Git identity user.name is not configured; run without --yes or set git config --global user.name first" }
    input "Full name for Git commits: " | str trim
  } else { $existing_name }
  let email = if ($existing_email | str trim | is-empty) {
    if $yes { fail "Git identity user.email is not configured; run without --yes or set git config --global user.email first" }
    input "Email address for Git commits: " | str trim
  } else { $existing_email }
  if ($name | is-empty) or ($email | is-empty) { fail "Git identity requires both a name and an email" }

  run-command git ["config" "--global" "user.name" $name] --dry-run=$dry_run | ignore
  run-command git ["config" "--global" "user.email" $email] --dry-run=$dry_run | ignore
  {ok: true name: $name email: $email detail: $"identity: ($name) <($email)>"}
}

# Point Git at the signing key and enable commit and tag signing.
export def setup-gpg-git [
  --dry-run # Show the config commands without running them.
]: nothing -> record {
  let key_id = (gpg-secret-key-id)
  if ($key_id | is-empty) { return {step: gpg-git ok: false detail: "no GPG signing key"} }
  let gpg_path = (first-external-path "gpg")
  run-command git ["config" "--global" "user.signingkey" $key_id] --dry-run=$dry_run | ignore
  run-command git ["config" "--global" "commit.gpgsign" "true"] --dry-run=$dry_run | ignore
  run-command git ["config" "--global" "tag.gpgsign" "true"] --dry-run=$dry_run | ignore
  run-command git ["config" "--global" "gpg.format" "openpgp"] --dry-run=$dry_run | ignore
  if not ($gpg_path | is-empty) {
    run-command git ["config" "--global" "gpg.program" $gpg_path] --dry-run=$dry_run | ignore
  }
  {step: gpg-git ok: true detail: $"Git signs commits with ($key_id)"}
}
