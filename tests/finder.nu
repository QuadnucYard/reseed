use std assert
use ./helpers.nu *
use ../lib/config.nu [load-config validate-config]
use ../lib/prelude.nu *
use ../integrations/finder.nu [finder-document-plist finder-enabled finder-info-plist finder-service-workflows]

# The macOS Finder context-menu services: the three Quick Actions, their
# exclusive acting contexts, the enabled default, the engine templates, and
# the generated bundles.
def test-finder-services [
  engine_root: path # Engine root.
  state_root: path # Private state template root.
] {
  let workflows = (finder-service-workflows)
  assert eq ($workflows.name) [OpenTerminalHere OpenCurrentFolderInVSCode OpenSelectedFolderInVSCode] "Finder service bundle names"
  assert eq ($workflows.display_name) ["Open Terminal Here" "Open in VS Code" "Open in VS Code"] "the two VS Code entries share the 'Open in VS Code' label"
  assert (($workflows | where context == current | all {|wf| $wf.script | str contains "front window" })) "current-folder services resolve the Finder front window"
  assert (not (($workflows | where name == OpenSelectedFolderInVSCode | get script | first | str contains "front window"))) "selected-folder service never resolves the front window"
  assert (($workflows | where name == OpenTerminalHere | get script | first | str contains "open -a iTerm")) "terminal service prefers iTerm2"
  assert (($workflows | where name == OpenCurrentFolderInVSCode | get script | first | str contains "code -r")) "current VS Code service reuses the last window"
  assert (($workflows | where name == OpenSelectedFolderInVSCode | get script | first | str contains "exit 0")) "selected-folder service exits silently without input"
  assert (($workflows | where name == OpenSelectedFolderInVSCode | get script | first | str contains 'open -a "Visual Studio Code"')) "selected service falls back to the VS Code app"

  assert (finder-enabled {}) "finder services default to enabled"
  assert (finder-enabled {software: {finder_services: {}}}) "an empty finder section defaults to enabled"
  assert (not (finder-enabled {software: {finder_services: {enabled: false}}})) "finder services can be disabled"

  let document_template = (open --raw ($engine_root | path join "templates" "macos" "finder" "document.wflow"))
  let info_template = (open --raw ($engine_root | path join "templates" "macos" "finder" "Info.plist"))

  let plist = (finder-document-plist $document_template ($workflows | get script | first))
  assert (($plist | str trim | str ends-with "</plist>")) "plist is a complete XML document"
  assert ($plist | str contains "com.apple.Automator.QuickAction") "plist marks the workflow as a Quick Action"
  assert ($plist | str contains "Run Shell Script") "plist uses the Run Shell Script action"
  assert ($plist | str contains "/bin/zsh") "plist runs the script with zsh"
  assert ($plist | str contains "open -a iTerm") "plist embeds the service script"
  assert (not ($plist | str contains "@@")) "plist generation replaces every placeholder"
  let escaped = (finder-document-plist $document_template "echo a & b < c > d")
  assert ($escaped | str contains "echo a &amp; b &lt; c &gt; d") "plist generation escapes XML specials"
  let info = (finder-info-plist $info_template "Open in VS Code" "com.reseed.finder.OpenSelectedFolderInVSCode")
  assert ($info | str contains "Open in VS Code") "bundle Info.plist carries the display name"
  assert ($info | str contains "com.reseed.finder.OpenSelectedFolderInVSCode") "bundle Info.plist carries a unique bundle identifier"
  assert (not ($info | str contains "@@")) "Info.plist generation replaces every placeholder"
  let other_info = (finder-info-plist $info_template "Open in VS Code" "com.reseed.finder.OpenCurrentFolderInVSCode")
  assert (not ($other_info | str contains "com.reseed.finder.OpenSelectedFolderInVSCode")) "duplicate display labels keep distinct bundle identifiers"

  let config = (load-config $state_root [personal])
  assert (finder-enabled $config) "the state template enables finder services"
  let minimal = {chezmoi: {enabled: false}}
  assert ((validate-config $state_root ($minimal | merge {software: {finder_services: {enabled: false}}})) | is-empty) "disabled finder services validate"
  assert ((validate-config $state_root ($minimal | merge {software: {finder_services: {enabled: "yes"}}})) | any {|issue| $issue.area == finder and ($issue.message | str contains "boolean") }) "finder services rejects non-boolean enabled"
  assert ((validate-config $state_root ($minimal | merge {software: {finder_services: [true]}})) | any {|issue| $issue.area == finder and ($issue.message | str contains "must be a record") }) "finder services rejects non-record shapes"
}

def main [] {
  let engine_root = ($env.FILE_PWD | path dirname)
  let state_root = ($engine_root | path join "templates" "state")

  test-finder-services $engine_root $state_root

  print "All Reseed finder tests passed"
}
