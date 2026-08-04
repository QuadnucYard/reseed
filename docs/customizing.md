# Customizing Reseed

## Dotfiles

From the Reseed repository, add files through chezmoi and explicitly select
this source:

```sh
chezmoi --source . add ~/.gitconfig
chezmoi --source . add ~/.config/nushell/config.nu
chezmoi --source . diff
```

Because `.chezmoiroot` contains `home`, chezmoi writes source files below that
directory while the recovery tooling remains outside the managed home tree.

Use chezmoi templates for OS, host, and profile differences. Secret values must
come from an external password manager or encrypted chezmoi data.

## Shared shell configuration

Keep shared behavior in one file and use only a thin adapter for each shell.
Starship follows this model:

- `~/.config/starship.toml` is the only prompt configuration.
- Fish loads Starship from `~/.config/fish/conf.d/starship.fish` on macOS.
- `scripts/configure-shells.nu` generates Starship's Nushell autoload file in
  `$nu.data-dir/vendor/autoload` on either platform.

Shell syntax is different, so activation cannot be one literal file. The
configuration and ownership remain unified, while generated initialization
code stays outside Git and is recreated after `mise install`.

Nushell's main configuration is platform-specific: `%APPDATA%\nushell` on
Windows and `~/Library/Application Support/nushell` on macOS. Add the actual
`config.nu` and `env.nu` through chezmoi after reviewing them for tokens. Keep
common authored modules under `~/.config/nushell/` and source them from thin
platform entry files.

## Software

Prefer the broadest portable owner that accurately represents the tool:

1. Put runtimes and portable command-line tools in `mise.toml`.
2. Put GUI applications and OS-specific packages in WinGet or Brewfiles.
3. Keep direct Cargo, pnpm, Bun, uv, pipx, or similar commands in a mise task
   only when mise cannot own that package cleanly.
4. Put machine-specific or role-specific manifests in a profile overlay.

Reseed observes existing Cargo, pnpm, Bun, uv, npm, and Yarn global state but
does not invent replacement lock formats for them. Review the observation files
and migrate portable commands to mise backends; retain a native mise task only
when the original package manager has required installation semantics.

This ordering reserves room for additional platforms and managers without
requiring a generic provider abstraction. A new integration is a focused
module exposing status, restore, update, reconcile, and verify operations; it
is then inserted into the explicit workflow stage where its dependencies are
available.

## Profiles

Profiles are recursive overlays on `config/recovery.nuon`. Later profiles win.
Records merge recursively and lists replace earlier lists. This makes package
manifest order and mise task order deterministic.

Mise configuration paths must be named `mise.toml` or
`mise.<environment>.toml`. Reseed maps the latter to mise's native `-E`
environment option instead of inventing its own tool-overlay semantics.

Use profiles for roles such as `personal`, `work`, or `studio`. Platform
selection is automatic, so a profile can be used on both Windows and macOS.

## Kopia

Enable Kopia only for selected paths unsuitable for Git:

```nu
kopia: {
  enabled: true
  snapshot_paths: ["~/.local/share/some-app"]
  restore: [
    {
      snapshot: "k1234567890abcdef"
      target: "~/.local/share/some-app"
    }
  ]
}
```

The repository connection and credentials must be configured separately.
Snapshot IDs are explicit so recovery never guesses which historical state to
restore.
