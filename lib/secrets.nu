# Pre-commit safety for the private state repository: credential scanning of
# changed files and the changed-file review summary used by `reseed backup
# --commit`. The guard is high-signal by design; it refuses known credential
# shapes but does not try to prove that everything else is safe.

use core.nu [command-exists run-command]

# High-signal credential content patterns. Each entry names a credential
# family and matches it anywhere in scanned text.
const secret_content_patterns = [
  {name: "private key" regex: '(?i)-----BEGIN (?:[A-Z0-9]+ )?PRIVATE KEY(?: BLOCK)?-----'}
  {name: "GitHub token" regex: '\bgh[pousr]_[A-Za-z0-9]{36}\b'}
  {name: "GitHub fine-grained token" regex: '\bgithub_pat_[A-Za-z0-9_]{22,}\b'}
  {name: "AWS access key" regex: '\bAKIA[0-9A-Z]{16}\b'}
  {name: "Google API key" regex: '\bAIza[0-9A-Za-z_-]{35}\b'}
  {name: "Slack token" regex: '\bxox[baprs]-[0-9A-Za-z-]{10,48}\b'}
  {name: "Stripe secret key" regex: '\b(?:sk|rk)_live_[0-9A-Za-z]{24}\b'}
  {name: "GitLab personal access token" regex: '\bglpat-[A-Za-z0-9_-]{20,}\b'}
  {name: "npm access token" regex: '\bnpm_[A-Za-z0-9]{36}\b'}
]

# High-signal credential filename patterns, matched against the basename.
const secret_name_patterns = [
  {name: "SSH private key" regex: '(?i)^id_(rsa|dsa|ecdsa|ed25519)(_sk)?$'}
  {name: "Git credentials" regex: '^\.git-credentials$'}
  {name: "netrc credentials" regex: '^\.netrc$'}
  {name: "pip credentials" regex: '^\.pypirc$'}
  {name: "generic credentials" regex: '^credentials$'}
  {name: "environment file" regex: '^\.env(\.[A-Za-z0-9_-]+)?$'}
]

# Credential-family names matching the file basename.
export def secret-name-matches [
  name: string # File basename to check.
]: nothing -> list<string> {
  $secret_name_patterns | where {|pattern| $name =~ $pattern.regex } | get name
}

# Credential-family names present in the given text.
export def secret-content-matches [
  content: string # Text to scan.
]: nothing -> list<string> {
  $secret_content_patterns | where {|pattern| $content =~ $pattern.regex } | get name
}

# Read a file for scanning, returning empty text when it is binary,
# unreadable, or too large to scan efficiently. Skipped files match nothing,
# so an empty result is indistinguishable from a clean file.
def scanable-content [
  path: path # File to read.
]: nothing -> string {
  let size = (try { (ls $path | get size | first) } catch { return "" })
  if $size > 1MiB { return "" }
  let content = (try { open --raw $path } catch { return "" })
  let kind = ($content | describe)
  if $kind == "byte stream" or $kind == "binary" { return "" }
  if ($content | str contains "\u{0}") { return "" }
  $content
}

# Changed files of the private state repository, sorted; deleted files are
# excluded and untracked directories are expanded to their files. Rename and
# copy entries contribute both the destination and the original path.
def changed-file-paths [
  root: path # Private state repository root.
]: nothing -> list<path> {
  if not (command-exists git) { return [] }
  let status = (run-command git ["-C" ($root | into string) "status" "--porcelain" "-z"] --allow-failure --quiet --capture)
  if $status.exit_code != 0 { return [] }
  let fields = ($status.stdout | split row "\u{0}")
  mut rels = []
  mut continuation = false
  for field in $fields {
    if ($field | str trim | is-empty) { $continuation = false; continue }
    let rel = if $continuation {
      # The continuation field of a rename/copy entry is a raw path.
      $field
    } else {
      # Each entry is "<XY> <path>" with -z; strip the status and separator.
      if ($field | str length) < 3 { $continuation = false; continue }
      $field | str substring 3..
    }
    # A rename or copy entry ("R " / "C ") always has exactly one
    # continuation field carrying the original path.
    $continuation = ($field | str starts-with "R ") or ($field | str starts-with "C ")
    if ($rel | str trim | is-empty) { continue }
    $rels = ($rels | append $rel)
  }
  mut paths = []
  for rel in ($rels | uniq) {
    let abs = ($root | path join $rel)
    if not ($abs | path exists) { continue }
    if ($abs | path type) == "dir" {
      # Normalize separators (backslashes are escapes in glob patterns) and
      # drop the trailing separator porcelain leaves on untracked directories.
      let pattern = (($abs | into string | str replace --all "\\" "/" | str trim --right --char "/") + "/**")
      $paths = ($paths | append (glob $pattern --no-dir))
    } else {
      $paths = ($paths | append $abs)
    }
  }
  $paths | uniq | sort
}

# Credential matches among the changed files, as {path, pattern} records.
export def scan-commit-secrets [
  root: path # Private state repository root.
]: nothing -> list<record> {
  mut matches = []
  for path in (changed-file-paths $root) {
    for pattern in (secret-name-matches ($path | path basename)) {
      $matches = ($matches | append {path: ($path | into string) pattern: $pattern})
    }
    for pattern in (secret-content-matches (scanable-content $path)) {
      $matches = ($matches | append {path: ($path | into string) pattern: $pattern})
    }
  }
  $matches | uniq
}

# File names and sizes of the changed files, for the pre-commit review
# summary. Directories are expanded to their files; deleted files are
# excluded.
export def commit-change-summary [
  root: path # Private state repository root.
]: nothing -> list<record> {
  changed-file-paths $root | each {|path|
    {
      path: ($path | path relative-to $root | into string)
      size: (try { (ls $path | get size | first) } catch { 0B })
    }
  }
}
