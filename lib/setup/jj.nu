# jj-specific setup: configuration access, installation, the jj identity
# half of the identity step, and commit signing with a behavior choice.

use ../core.nu [command-exists detect-os run-command]
use ./shared.nu [first-external-path gpg-secret-key-id]

# jj user configuration value, or "" when unset.
export def jj-config-get [key: string]: nothing -> string {
  if not (command-exists jj) { return "" }
  let value = (run-command jj ["config" "get" $key] --allow-failure --quiet)
  if $value.exit_code != 0 { "" } else { $value.stdout | str trim }
}

# Whether jj is configured to sign with the gpg backend.
export def jj-signing-configured []: nothing -> bool {
  ((jj-config-get "signing.backend") == "gpg") and not ((jj-config-get "signing.key") | is-empty)
}

# Signing behaviors jj applies when rewriting commits, in prompt order.
export def jj-signing-behaviors []: nothing -> list<string> {
  [drop keep own force]
}

# Install jj when missing: mise when available (reseed-owned), then the
# platform package manager.
export def setup-jj-prereq [
  --dry-run # Show the install without running it.
]: nothing -> record {
  if (command-exists jj) { return {step: jj-prereq ok: true detail: "jj is installed"} }
  if $dry_run { return {step: jj-prereq ok: true detail: "would install jj"} }
  let installed = (try {
    if (command-exists mise) {
      run-command mise ["use" "-g" "jj@latest"] --allow-failure
    } else if (detect-os) == "windows" {
      run-command winget ["install" "-e" "--id" "Jujutsu.Jujutsu" "--accept-package-agreements" "--accept-source-agreements"] --allow-failure
    } else {
      run-command brew ["install" "jujutsu"] --allow-failure
    }
  } catch {|error|
    {exit_code: 127 stdout: "" stderr: ($error.msg? | default ($error | to nuon))}
  })
  if (command-exists jj) {
    {step: jj-prereq ok: true detail: "jj installed"}
  } else {
    {step: jj-prereq ok: false detail: $"jj install failed: ($installed.stderr | str trim)"}
  }
}

# Mirror the resolved Git identity into jj.
export def setup-jj-identity [
  name: string # Identity name to mirror from Git.
  email: string # Identity email to mirror from Git.
  --dry-run # Show the config commands without running them.
]: nothing -> record {
  run-command jj ["config" "set" "--user" "user.name" $name] --dry-run=$dry_run | ignore
  run-command jj ["config" "set" "--user" "user.email" $email] --dry-run=$dry_run | ignore
  {ok: true detail: $"jj identity: ($name) <($email)>"}
}

# Point jj at the same signing key and backend, asking how to behave when
# rewriting commits (default: sign the commits the user authors).
export def setup-gpg-jj [
  --behavior: string = "" # Signing behavior override: drop, keep, own, force.
  --yes # Use the default behavior (own) without prompting.
  --dry-run # Show the config commands without running them.
]: nothing -> record {
  if $dry_run {
    return {step: gpg-jj ok: true detail: (if (command-exists jj) { "would configure jj signing" } else { "jj is not installed" })}
  }
  if not (command-exists jj) { return {step: gpg-jj ok: false detail: "jj is not installed"} }
  let behavior = if ($behavior | is-not-empty) {
    $behavior
  } else if $yes {
    "own"
  } else {
    print "jj signing behavior when rewriting commits:"
    print "  drop  - drop signatures from rewritten commits"
    print "  keep  - re-sign signed commits you authored"
    print "  own   - sign commits you author (default)"
    print "  force - sign every modified commit"
    let answer = (input "Signing behavior [own] " | str trim | str lowercase)
    if ($answer | is-empty) { "own" } else { $answer }
  }
  if $behavior not-in (jj-signing-behaviors) {
    return {step: gpg-jj ok: false detail: $"unknown jj signing behavior: ($behavior)"}
  }
  let key_id = (gpg-secret-key-id)
  if ($key_id | is-empty) { return {step: gpg-jj ok: false detail: "no GPG signing key"} }
  let gpg_path = (first-external-path "gpg")
  run-command jj ["config" "set" "--user" "signing.backend" "gpg"] --dry-run=$dry_run | ignore
  run-command jj ["config" "set" "--user" "signing.behavior" $behavior] --dry-run=$dry_run | ignore
  run-command jj ["config" "set" "--user" "signing.key" $key_id] --dry-run=$dry_run | ignore
  if not ($gpg_path | is-empty) {
    run-command jj ["config" "set" "--user" "signing.backends.gpg.program" $gpg_path] --dry-run=$dry_run | ignore
  }
  {step: gpg-jj ok: true detail: $"jj signs commits with ($key_id) (behavior: ($behavior))"}
}
