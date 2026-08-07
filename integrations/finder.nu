use ../lib/prelude.nu *

# macOS Finder context-menu services (Automator Quick Actions) installed into
# the user's ~/Library/Services directory. Each service runs a zsh script
# with the right-clicked files or folders passed as arguments.
#
# Two exclusive contexts exist, and each service acts on exactly one:
# "current" services resolve the folder of the frontmost Finder window (the
# folder you are viewing, e.g. a right-click on empty space) and ignore the
# selection; "selected" services act only on the right-clicked items and do
# nothing when nothing is selected.
#
# The Quick Action bundle structure ships as engine templates under
# templates/macos/finder/; the zsh scripts are generated here because they
# are the per-service behavior and are asserted by the tests.

# The three Finder services: bundle name, menu display name, acting context,
# and the zsh script each one runs. The two VS Code entries share the "Open
# in VS Code" label; each acts on exactly one exclusive context, so the
# right-click location picks the behavior. The bundle names keep the contexts
# apart for status, reconcile, and verification.
export def finder-service-workflows []: nothing -> list<record> {
  [
    {name: OpenTerminalHere display_name: "Open Terminal Here" context: current script: (open-terminal-script)}
    {name: OpenCurrentFolderInVSCode display_name: "Open in VS Code" context: current script: (open-current-vscode-script)}
    {name: OpenSelectedFolderInVSCode display_name: "Open in VS Code" context: selected script: (open-selected-vscode-script)}
  ]
}

# zsh snippet resolving the frontmost Finder window's folder. Yields the
# home directory when no window is open or the query fails, so a service
# always has a usable target.
def finder-current-dir-snippet []: nothing -> string {
  'dir=$(osascript -e "tell application \"Finder\" to get POSIX path of (target of front window as alias)" 2>/dev/null)
if [ -z "$dir" ] || [ ! -d "$dir" ]; then dir="$HOME"; fi'
}

# Open the frontmost Finder window's folder in a terminal: iTerm2 when
# installed, otherwise the built-in Terminal.app.
def open-terminal-script []: nothing -> string {
  [
    (finder-current-dir-snippet)
    'if [ -d /Applications/iTerm.app ]; then'
    '  open -a iTerm "$dir"'
    'else'
    '  open -a Terminal "$dir"'
    'fi'
  ] | str join "\n"
}

# Open the frontmost Finder window's folder in VS Code, reusing the last
# window through the code CLI when it exists.
def open-current-vscode-script []: nothing -> string {
  [
    (finder-current-dir-snippet)
    'if command -v code >/dev/null 2>&1; then'
    '  code -r "$dir"'
    'else'
    '  open -a "Visual Studio Code" "$dir"'
    'fi'
  ] | str join "\n"
}

# Open the right-clicked selection in VS Code (a folder directly, a file in
# its containing folder), reusing the last window. Exits silently when no
# selection was passed: this service never falls back to the window folder.
def open-selected-vscode-script []: nothing -> string {
  'if [ "$#" -eq 0 ]; then
  exit 0
fi
for path in "$@"; do
  if [ -d "$path" ]; then
    dir="$path"
  else
    dir="${path%/*}"
    if [ ! -d "$dir" ]; then
      continue
    fi
  fi
  if command -v code >/dev/null 2>&1; then
    code -r "$dir"
  else
    open -a "Visual Studio Code" "$dir"
  fi
done'
}

# Escape the XML-significant characters for plist text content.
def xml-escape [value: string]: nothing -> string {
  $value
  | str replace --all "&" "&amp;"
  | str replace --all "<" "&lt;"
  | str replace --all ">" "&gt;"
}

# The document.wflow XML of one Quick Action bundle: the given template with
# the zsh script embedded and fresh identifiers for every UUID slot.
export def finder-document-plist [template: string, script: string]: nothing -> string {
  let action_uuid = (random uuid)
  $template
  | str replace --all "@@COMMAND_STRING@@" (xml-escape $script)
  | str replace --all "@@UUID_ACTION@@" $action_uuid
  | str replace --all "@@UUID_INPUT@@" (random uuid)
  | str replace --all "@@UUID_OUTPUT@@" (random uuid)
  | str replace --all "@@UUID_ARG1@@" (random uuid)
  | str replace --all "@@UUID_ARG2@@" (random uuid)
  | str replace --all "@@UUID_ARG3@@" (random uuid)
  | str replace --all "@@UUID_ARG4@@" (random uuid)
  | str replace --all "@@UUID_ARG5@@" (random uuid)
}

# The Info.plist XML of one Quick Action bundle. The bundle identifier is
# unique per service even though the two VS Code entries share a display
# name, so Finder registers them as distinct menu items.
export def finder-info-plist [
  template: string # Info.plist template.
  display_name: string # Menu label shown to the user.
  bundle_id: string # Unique bundle identifier for this service.
]: nothing -> string {
  $template
  | str replace --all "@@DISPLAY_NAME@@" (xml-escape $display_name)
  | str replace --all "@@BUNDLE_ID@@" (xml-escape $bundle_id)
}

# Engine template file for the Quick Action bundles.
def finder-template-path [
  engine_root: path # Engine directory.
  name: string # Template file name.
]: nothing -> path {
  $engine_root | path join "templates" "macos" "finder" $name
}

# The shared document.wflow template (placeholders @@COMMAND_STRING@@ and the
# @@UUID_*@@ slots).
def finder-document-template [
  engine_root: path # Engine directory.
]: nothing -> string {
  open --raw (finder-template-path $engine_root "document.wflow")
}

# The shared Info.plist template (placeholders @@DISPLAY_NAME@@ and
# @@BUNDLE_ID@@).
def finder-info-template [
  engine_root: path # Engine directory.
]: nothing -> string {
  open --raw (finder-template-path $engine_root "Info.plist")
}

# Whether the Finder context-menu services are desired. Defaults to enabled
# so a fresh state template gets them on macOS.
export def finder-enabled [
  config: record # Loaded configuration.
]: nothing -> bool {
  (($config.software? | default {}).finder_services? | default {}).enabled? | default true
}

# The per-user Services directory that holds Automator Quick Actions.
export def finder-services-dir []: nothing -> path {
  $nu.home-dir | path join "Library" "Services"
}

# Installed document.wflow contents for a service, or empty when absent.
def finder-installed-document [
  workflow: record # Finder service workflow.
]: nothing -> string {
  let path = (finder-services-dir | path join $"($workflow.name).workflow" "Contents" "document.wflow")
  if ($path | path exists) { open --raw $path } else { "" }
}

# True when the installed document contains the expected script and marks the
# bundle as a Quick Action.
def finder-installed-matches [
  workflow: record # Finder service workflow.
]: nothing -> bool {
  let installed = (finder-installed-document $workflow)
  ($installed | str contains (xml-escape $workflow.script)) and ($installed | str contains "com.apple.Automator.QuickAction")
}

# Availability and installed-bundle health for the Finder services.
export def finder-status [
  root: path # Private state root.
  config: record # Loaded configuration.
]: nothing -> record {
  let applicable = ((detect-os) == "macos")
  {
    tool: finder
    enabled: (finder-enabled $config)
    applicable: $applicable
    available: $applicable
    desired: (finder-service-workflows | each {|workflow|
      {
        name: $workflow.display_name
        context: $workflow.context
        installed: ((finder-installed-document $workflow) != "")
        matches: (finder-installed-matches $workflow)
      }
    })
  }
}

# Write the three Finder Quick Action bundles into ~/Library/Services and
# restart Finder so the context menu picks them up. Idempotent: existing
# bundles are regenerated from the engine templates.
export def finder-restore [
  engine_root: path # Engine directory providing the bundle templates.
  root: path # Private state root.
  config: record # Loaded configuration.
  --dry-run # Report the writes without changing files.
] {
  if not (finder-enabled $config) or ((detect-os) != "macos") { return }
  let document_template = (finder-document-template $engine_root)
  let info_template = (finder-info-template $engine_root)
  let services = (finder-services-dir)
  for workflow in (finder-service-workflows) {
    let contents = ($services | path join $"($workflow.name).workflow" "Contents")
    if $dry_run {
      info $"would write Finder service: ($contents | path join "document.wflow")"
    } else {
      mkdir $contents
      ((finder-document-plist $document_template $workflow.script) + "\n") | save --force ($contents | path join "document.wflow")
      ((finder-info-plist $info_template $workflow.display_name $"com.reseed.finder.($workflow.name)") + "\n") | save --force ($contents | path join "Info.plist")
      info $"wrote Finder service: ($contents | path dirname)"
    }
  }
  if $dry_run {
    info "would restart Finder to register the new context menu items"
    return
  }
  let restart = (run-command killall ["Finder"] --allow-failure --quiet)
  if $restart.exit_code == 0 {
    info "restarted Finder to register the new context menu items"
  } else {
    warning "restart Finder (or log out) to see the new context menu items"
  }
}

# Regenerate the Finder services; the bundles are engine-generated, so an
# update is the same idempotent reapply as restore.
export def finder-update [
  engine_root: path # Engine directory providing the bundle templates.
  root: path # Private state root.
  config: record # Loaded configuration.
  --dry-run # Report the writes without changing files.
] {
  finder-restore $engine_root $root $config --dry-run=$dry_run
}

# Compare the desired Finder services with the installed bundles, report-only.
export def finder-reconcile [
  root: path # Private state root.
  config: record # Loaded configuration.
  --dry-run # Accepted for contract parity; reconcile never writes anyway.
]: nothing -> record {
  if not (finder-enabled $config) or ((detect-os) != "macos") {
    return {tool: finder applicable: false desired_only: [] observed_only: []}
  }
  let services = (finder-services-dir)
  let observed = if ($services | path exists) {
    ls $services
    | where {|entry| $entry.name | str ends-with ".workflow" }
    | get name
    | path basename
    | str replace ".workflow" ""
    | sort
  } else {
    []
  }
  let desired = (finder-service-workflows | get name | sort)
  {
    tool: finder
    applicable: true
    desired_only: ($desired | where {|name| $name not-in $observed })
    observed_only: ($observed | where {|name| $name not-in $desired })
  }
}

# Verification checks for the Finder services: each bundle installed with the
# expected script.
export def finder-verify [
  root: path # Private state root.
  config: record # Loaded configuration.
]: nothing -> list<record> {
  if not (finder-enabled $config) or ((detect-os) != "macos") { return [] }
  finder-service-workflows | each {|workflow|
    let installed = (finder-installed-document $workflow)
    let context_label = (($workflow.context | into string) + " folder")
    {
      check: $"Finder service: ($workflow.display_name) ($context_label)"
      ok: (finder-installed-matches $workflow)
      detail: (if $installed == "" {
        "not installed"
      } else if ($installed | str contains (xml-escape $workflow.script)) {
        "installed"
      } else {
        "stale; rerun restore"
      })
    }
  }
}

# Finder services are generated from the engine, not user state, so there is
# nothing to capture.
export def finder-backup [
  root: path # Private state root.
  config: record # Loaded configuration.
  --dry-run # Accepted for contract parity.
] {
}
