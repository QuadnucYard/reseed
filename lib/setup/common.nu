# Setup steps shared by multiple purposes: the Git and jj user identity and
# GitHub CLI authentication.

use ../core.nu [command-exists run-command]
use ./shared.nu [ask-default-yes gh-auth-status]
use ./git.nu [setup-git-identity]
use ./jj.nu [setup-jj-identity]

# Configure the Git user identity and, when available, mirror it into jj,
# prompting only for missing values.
export def setup-identity [
  config: record # Loaded configuration.
  --yes # Apply defaults; fail when the identity is missing.
  --dry-run # Show the config commands without running them.
]: nothing -> record {
  let git = (setup-git-identity --yes=$yes --dry-run=$dry_run)
  if not $git.ok { return $git }
  let jj_part = if (command-exists jj) {
    let jj = (setup-jj-identity $git.name $git.email --dry-run=$dry_run)
    if not $jj.ok { return {step: identity ok: false detail: $jj.detail} }
    " and jj"
  } else { "" }
  {step: identity ok: true detail: $"configured git($jj_part) identity: ($git.name) <($git.email)>"}
}

# Ensure the GitHub CLI is authenticated with the scopes needed by the
# upload steps in the current plan.
export def setup-gh-auth [
  --yes # Do not prompt; fail when authentication is missing.
  --dry-run # Show the auth commands without running them.
  --needs-gpg-upload # Also require the write:gpg_key scope.
]: nothing -> record {
  if not (command-exists gh) {
    return {step: gh-auth ok: false detail: "gh is not installed"}
  }
  mut status = (gh-auth-status)
  if not $status.authed {
    if $dry_run { return {step: gh-auth ok: true detail: "would log in with gh auth login"} }
    if not (ask-default-yes "GitHub CLI is not authenticated; log in now?") {
      return {step: gh-auth ok: false detail: "GitHub CLI is not authenticated"}
    }
    run-command gh ["auth" "login"] | ignore
    $status = (gh-auth-status)
    if not $status.authed {
      return {step: gh-auth ok: false detail: "GitHub CLI login did not complete"}
    }
  }
  let needed = if $needs_gpg_upload { [admin:public_key write:gpg_key] } else { [admin:public_key] }
  for scope in $needed {
    if $scope in $status.scopes { continue }
    if $dry_run { continue }
    if not (ask-default-yes $"The GitHub token lacks the '($scope)' scope; refresh it?") {
      return {step: gh-auth ok: false detail: $"missing GitHub scope: ($scope)"}
    }
    run-command gh ["auth" "refresh" "-h" "github.com" "-s" $scope] | ignore
    $status = (gh-auth-status)
    if $scope not-in $status.scopes {
      return {step: gh-auth ok: false detail: $"missing GitHub scope: ($scope)"}
    }
  }
  {step: gh-auth ok: true detail: $"authenticated as ($status.login)"}
}
