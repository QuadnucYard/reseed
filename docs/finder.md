# Finder context menu (macOS)

Reseed installs macOS Finder context-menu items as Automator Quick Actions
under `~/Library/Services`. They are restored by the `macos-finder` stage of
`reseed restore` (also on `reseed update`) and managed directly through the
dedicated entry point:

```sh
nu reseed.nu finder status
nu reseed.nu finder restore
nu reseed.nu finder verify
```

## Menu items

| Menu item | Context | Action |
| --- | --- | --- |
| Open Terminal Here | current folder | Opens the frontmost Finder window's folder in a terminal: iTerm2 when installed, otherwise Terminal.app |
| Open in VS Code | current folder | Opens the frontmost Finder window's folder in VS Code, reusing the last window (`code -r`, else the VS Code app) |
| Open in VS Code | selected folder | Opens the right-clicked selection in VS Code — a folder directly, or a file in its containing folder |

The two "Open in VS Code" entries share the same label; the right-click
location picks the behavior. The contexts are exclusive: "current folder"
items resolve the folder of the frontmost Finder window (a right-click on
empty space) and ignore the selection; the "selected folder" item acts only
on the right-clicked items and exits silently when nothing is selected. It
never falls back to the window's folder. Each entry carries its own bundle
identifier, so Finder registers them as distinct menu items.

## Configuration

The stage is gated by `software.finder_services.enabled`, which defaults to
true:

```nuon
software: {
  finder_services: {
    enabled: true
  }
}
```

Set it to false to skip the stage. Verification runs under `reseed verify`
and `reseed finder verify`; `reseed status` reports per-service installation
state. The Quick Action bundles are generated from engine templates
(`templates/macos/finder/`), so backup captures nothing.

## Notes

- Restart Finder (or log out) if the items do not appear; `finder restore`
  restarts Finder automatically.
- The first use of a "current" item may prompt for Automation permission
  ("Automator wants to control Finder") in System Settings > Privacy &
  Security > Automation; allow it once.
- The bundles are hand-generated on the target machine from the engine
  templates, so an engine update is picked up by the next restore or
  `reseed finder restore`.
