# Shared utilities: platform detection, logging, command execution with
# dry-run and failure capture, path and URL helpers, and confirmation.

# Name of the current platform, normalized to lowercase ("windows", "macos",
# or the raw OS name for anything else).
export def detect-os []: nothing -> string {
  let name = ($nu.os-info.name | str lowercase)
  if $name == "windows" { "windows" } else if $name == "macos" { "macos" } else { $name }
}

# True when the named executable is on PATH (external or built-in).
export def command-exists [
  name: string # Executable name to look up.
]: nothing -> bool {
  (which $name | is-not-empty)
}

# Print an informational message in the reseed banner style.
export def info [
  message: string # Message to print.
] {
  print $"(ansi cyan_bold)reseed:(ansi reset) ($message)"
}

# Print a warning to stderr.
export def warning [
  message: string # Message to print.
] {
  print --stderr $"(ansi yellow_bold)warning:(ansi reset) ($message)"
}

# Raise an error with the given message.
export def fail [
  message: string # Error message.
] {
  error make {msg: $message}
}

# Expand a leading ~ or ~/ or ~\ to the home directory; other values are
# expanded without resolving symlinks.
export def expand-home [
  value: string # Path that may start with ~.
]: nothing -> path {
  if $value == "~" {
    $nu.home-dir
  } else if ($value | str starts-with "~/") or ($value | str starts-with "~\\") {
    $nu.home-dir | path join ($value | str substring 2..)
  } else {
    $value | path expand --no-symlink
  }
}

# Redact the userinfo of URLs so credentials never appear in logs or errors.
# Matches "scheme://anything-without-/@-or-space@" and replaces the userinfo
# (including a possible password) with ***.
export def scrub-url [
  value: string # URL that may contain credentials.
]: nothing -> string {
  $value | str replace --regex '(?i)([a-z][a-z0-9+.-]*://)[^/@\s]+@' '$1***@'
}

# Quote an argument for display when it contains spaces or tabs.
def printable-arg [
  value: string # Argument to display.
]: nothing -> string {
  let scrubbed = (scrub-url $value)
  if ($scrubbed | str contains " ") or ($scrubbed | str contains "\t") {
    $'"($scrubbed | str replace --all '"' '\\"')"'
  } else {
    $scrubbed
  }
}

# Render a program plus arguments as a single display string, quoting values
# that contain whitespace and redacting URL credentials.
export def show-command [
  program: string # Program name.
  args: list<string> = [] # Arguments.
]: nothing -> string {
  ([(printable-arg $program)] | append ($args | each {|arg| printable-arg $arg }) | str join " ")
}

# Run an external program, returning {exit_code, stdout, stderr, skipped}.
#
# Output streams to the terminal by default so long-running actions show
# progress; with --capture the stdout and stderr are instead collected into
# the result record for parsing. --dry-run prints the command without
# executing it. --allow-failure captures failures (including a missing
# executable, reported as exit 127) into the result record instead of failing.
# Any other nonzero exit aborts with a redacted error message.
export def run-command [
  program: string # Program to run.
  args: list<string> = [] # Arguments to pass.
  --cwd: path # Working directory for the child process.
  --environment: record = {} # Environment variables to set for the child.
  --dry-run # Print the command without executing it.
  --allow-failure # Return the result instead of failing on nonzero exit.
  --quiet # Suppress the "running:" banner.
  --capture # Collect stdout/stderr into the result instead of streaming them.
]: nothing -> record {
  let shown = (show-command $program $args)
  if $dry_run {
    info $"would run: ($shown)"
    return {exit_code: 0 stdout: "" stderr: "" skipped: true}
  }

  if not $quiet { info $"running: ($shown)" }
  let invoke = {| | if $cwd == null {
    run-external $program ...$args
  } else {
    do { cd $cwd; run-external $program ...$args }
  }}
  let result = if $capture {
    # Nushell aborts on nonzero external exit unless the output is consumed,
    # so capture through "complete" to read it and the exit code back.
    let invoke = {| | if $cwd == null {
      run-external $program ...$args | complete
    } else {
      do { cd $cwd; run-external $program ...$args | complete }
    }}
    if $allow_failure {
      try {
        if ($environment | is-empty) {
          do $invoke
        } else {
          with-env $environment { do $invoke }
        }
      } catch {|error|
        # A command that cannot be started (e.g. not on PATH) surfaces as an
        # exception; normalize it to exit 127 like a shell would.
        {exit_code: 127 stdout: "" stderr: ($error.msg? | default ($error | to nuon)) skipped: false}
      }
    } else if ($environment | is-empty) {
      do $invoke
    } else {
      with-env $environment { do $invoke }
    }
  } else {
    # Streamed mode: output appears live, and a nonzero exit (or an
    # unstartable command) surfaces as a catchable error carrying the code.
    try {
      if ($environment | is-empty) {
        do $invoke
      } else {
        with-env $environment { do $invoke }
      }
      {exit_code: 0 stdout: "" stderr: "" skipped: false}
    } catch {|error|
      {exit_code: ($error.exit_code? | default 127) stdout: "" stderr: "" skipped: false}
    }
  }

  let normalized = ($result | upsert skipped false)
  if ($normalized.exit_code != 0) and (not $allow_failure) {
    if $capture {
      let detail = if ($normalized.stderr | str trim | is-empty) {
        $normalized.stdout | str trim
      } else {
        $normalized.stderr | str trim
      }
      fail $"Command failed with exit code ($normalized.exit_code): ($shown)\n(scrub-url $detail)"
    }
    fail $"Command failed with exit code ($normalized.exit_code): ($shown)"
  }
  $normalized
}

# Run a command, warning instead of failing when it exits nonzero, so a
# package-manager failure never aborts the restore or update. Output streams
# live; the returned record carries the exit code (and stderr when captured).
# Callers still count failures so the workflow can exit nonzero at the end.
export def run-or-warn [
  program: string # Program to run.
  args: list<string> = [] # Arguments to pass.
  --cwd: path # Working directory for the child process.
  --environment: record = {} # Environment variables to set for the child.
  --dry-run # Print the command without executing it.
  --quiet # Suppress the "running:" banner.
  --capture # Collect stdout/stderr into the result instead of streaming them.
  --label: string = "" # Context prepended to the warning message.
]: nothing -> record {
  let result = (run-command $program $args --cwd=$cwd --environment=$environment --dry-run=$dry_run --allow-failure --quiet=$quiet --capture=$capture)
  if $result.exit_code != 0 {
    let detail = (if $capture { ($result.stderr | str trim) } else { "" })
    let detail = (if ($detail | is-empty) { $"exit code ($result.exit_code)" } else { $detail })
    warning (if ($label | is-empty) { $"Command failed: ($detail)" } else { $"($label) failed: ($detail)" })
  }
  $result
}

# Ask the user for y/N confirmation; --yes accepts without prompting.
export def confirm [
  message: string # Prompt text.
  --yes # Accept without asking.
]: nothing -> bool {
  if $yes { return true }
  let answer = (input $"($message) [y/N] " | str trim | str lowercase)
  $answer in ["y" "yes"]
}

# Fail unless the file or directory at the given path exists.
export def require-file [
  path: path # Path that must exist.
  label: string # Human-readable name used in the error.
] {
  if not ($path | path exists) {
    fail $"Missing ($label): ($path)"
  }
}

# Current timestamp in ISO 8601 local time with offset, used for checkpoints
# and observation filenames.
export def now-string []: nothing -> string {
  date now | format date "%Y-%m-%dT%H:%M:%S%:z"
}
