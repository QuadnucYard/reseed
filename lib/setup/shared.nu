# Shared machine-state detection and parsing for the guided setup wizard:
# SSH and GPG key status, GitHub CLI authentication, and the yes-by-default
# prompt helper.

use ../core.nu [command-exists expand-home run-command]

# Machine hostname for key titles, from the interpreter or the hostname
# command, falling back to "machine".
export def machine-name []: nothing -> string {
  let direct = ($nu.os-info.hostname? | default "")
  if not ($direct | is-empty) { return $direct }
  if not (command-exists hostname) { return "machine" }
  let from_command = ((run-command hostname [] --allow-failure --quiet).stdout | str trim)
  if ($from_command | is-empty) { "machine" } else { $from_command }
}

# First external executable path for a name, or "" when unavailable.
export def first-external-path [name: string]: nothing -> string {
  let matches = (which $name | where type == external)
  if ($matches | is-empty) { "" } else { ($matches | first | get path | path expand) | into string }
}

# Status of the default SSH key pair.
export def ssh-key-status []: nothing -> record {
  let key = (expand-home "~/.ssh/id_ed25519")
  let pub = $"($key).pub"
  {
    key_path: ($key | into string)
    pub_path: ($pub | into string)
    key_present: (($key | path exists) and ($pub | path exists))
  }
}

# Whether the SSH agent is running (ssh-add -l succeeds when it is).
export def ssh-agent-running []: nothing -> bool {
  if not (command-exists ssh-add) { return false }
  (run-command ssh-add ["-l"] --allow-failure --quiet).exit_code == 0
}

# GitHub CLI authentication status: a working token probe plus the token's
# declared scopes.
export def gh-auth-status []: nothing -> record {
  if not (command-exists gh) { return {authed: false login: "" scopes: []} }
  let probe = (run-command gh ["api" "user" "--jq" ".login"] --allow-failure --quiet)
  if $probe.exit_code != 0 { return {authed: false login: "" scopes: []} }
  let status = (run-command gh ["auth" "status"] --allow-failure --quiet)
  {authed: true login: ($probe.stdout | str trim) scopes: (parse-gh-scopes $status.stdout)}
}

# Extract the token scopes from `gh auth status` output; [] when absent.
export def parse-gh-scopes [text: string]: nothing -> list<string> {
  let matches = ($text | lines | where {|line| $line | str contains "Token scopes:" })
  if ($matches | is-empty) { return [] }
  let line = ($matches | first)
  if ($line | str trim | is-empty) { return [] }
  $line
    | str replace --regex '.*Token scopes:\s*' ""
    | str replace --all "'" ""
    | split row ","
    | each {|scope| $scope | str trim }
    | where {|scope| not ($scope | is-empty) }
}

# Long key id of the first GPG secret key, or "" when none exists.
export def gpg-secret-key-id []: nothing -> string {
  if not (command-exists gpg) { return "" }
  let listing = (run-command gpg ["--list-secret-keys" "--with-colons" "--keyid-format=long"] --allow-failure --quiet)
  if $listing.exit_code != 0 { return "" }
  let ids = (parse-gpg-secret-ids $listing.stdout)
  if ($ids | is-empty) { "" } else { $ids | first }
}

# Parse secret key ids (field 5) from `gpg --with-colons` output.
export def parse-gpg-secret-ids [colons: string]: nothing -> list<string> {
  $colons
    | lines
    | where {|line| $line | str starts-with "sec:" }
    | each {|line| $line | split row ":" | get -o 4 | default "" }
    | where {|id| not ($id | is-empty) }
}

# Prompt a y/N-style question whose default answer is yes.
export def ask-default-yes [message: string]: nothing -> bool {
  let answer = (input $"($message) [Y/n] " | str trim | str lowercase)
  not ($answer in ["n" "no"])
}
