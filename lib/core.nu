export def detect-os []: nothing -> string {
  let name = ($nu.os-info.name | str downcase)
  if $name == "windows" { "windows" } else if $name == "macos" { "macos" } else { $name }
}

export def command-exists [name: string]: nothing -> bool {
  (which $name | is-not-empty)
}

export def info [message: string] {
  print $"(ansi cyan_bold)reseed:(ansi reset) ($message)"
}

export def warning [message: string] {
  print --stderr $"(ansi yellow_bold)warning:(ansi reset) ($message)"
}

export def fail [message: string] {
  error make {msg: $message}
}

export def expand-home [value: string]: nothing -> path {
  if $value == "~" {
    $nu.home-dir
  } else if ($value | str starts-with "~/") or ($value | str starts-with "~\\") {
    $nu.home-dir | path join ($value | str substring 2..)
  } else {
    $value | path expand --no-symlink
  }
}

def printable-arg [value: string]: nothing -> string {
  if ($value | str contains " ") or ($value | str contains "\t") {
    $'"($value | str replace --all '"' '\\"')"'
  } else {
    $value
  }
}

export def show-command [program: string args: list<string> = []]: nothing -> string {
  ([(printable-arg $program)] | append ($args | each {|arg| printable-arg $arg }) | str join " ")
}

export def run-command [
  program: string
  args: list<string> = []
  --cwd: path
  --dry-run
  --allow-failure
  --quiet
]: nothing -> record {
  let shown = (show-command $program $args)
  if $dry_run {
    info $"would run: ($shown)"
    return {exit_code: 0 stdout: "" stderr: "" skipped: true}
  }

  if not $quiet { info $"running: ($shown)" }
  let result = if $cwd == null {
    run-external $program ...$args | complete
  } else {
    do { cd $cwd; run-external $program ...$args | complete }
  }

  let normalized = ($result | upsert skipped false)
  if ($normalized.exit_code != 0) and (not $allow_failure) {
    let detail = if ($normalized.stderr | str trim | is-empty) {
      $normalized.stdout | str trim
    } else {
      $normalized.stderr | str trim
    }
    fail $"Command failed (exit ($normalized.exit_code)): ($shown)\n($detail)"
  }
  $normalized
}

export def confirm [message: string --yes]: nothing -> bool {
  if $yes { return true }
  let answer = (input $"($message) [y/N] " | str trim | str downcase)
  $answer in ["y" "yes"]
}

export def require-file [path: path label: string] {
  if not ($path | path exists) {
    fail $"Missing ($label): ($path)"
  }
}

export def now-string []: nothing -> string {
  date now | format date "%Y-%m-%dT%H:%M:%S%:z"
}
