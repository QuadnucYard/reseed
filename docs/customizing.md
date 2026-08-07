# Customizing Reseed

## Dotfiles

From the private state repository, add files through chezmoi and explicitly
select that source:

```sh
chezmoi --source ~/.local/share/reseed add ~/.gitconfig
chezmoi --source ~/.local/share/reseed add ~/.config/nushell/config.nu
chezmoi --source ~/.local/share/reseed diff
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
  `$nu.data-dir/vendor/autoload` and the shared manager-path adapters.

Shell syntax is different, so activation cannot be one literal file. The
configuration and ownership remain unified, while generated initialization
code stays outside Git and is recreated after `mise install`. Nushell and Fish
load their generated adapters automatically; PowerShell and POSIX shells use
the generated profile snippets from `~/.local/share/reseed/shell/`.

Nushell's main configuration is platform-specific: `%APPDATA%\nushell` on
Windows and `~/Library/Application Support/nushell` on macOS. Add the actual
`config.nu` and `env.nu` through chezmoi after reviewing them for tokens. Keep
common authored modules under `~/.config/nushell/` and source them from thin
platform entry files.

## Software

Choose one of the three ownership layers and keep each package in its owner:

1. Bootstrap prerequisites are Git, chezmoi, Nushell, and mise. Bootstrap
   scripts install them; do not add them to private WinGet or Brewfiles.
2. Put shared runtimes and portable tools supported by mise in `[tools]`.
3. Put GUI applications and OS-specific packages in WinGet or Brewfiles.
4. Put Cargo binary crates in the configured `cargo-binstall` manifest under
   `packages/cargo/`; every configured Cargo binary is installed through
   Cargo-binstall.
5. Put uv tools in `packages/uv/` and Node package-manager globals in the
   sibling `packages/node/pnpm/`, `packages/node/yarn/`, or `packages/node/bun/`
   manifests.
6. Keep direct Cargo, pnpm, Yarn, Bun, uv, pipx, or similar commands in a mise
   task only when the package cannot be represented by a declarative
   integration.
7. Put machine-specific or role-specific manifests in a profile overlay.

Reseed observes existing Cargo, pnpm, Bun, uv, npm, and Yarn global state. Use
the configured Cargo-binstall, uv, pnpm, Yarn, and Bun manifests for packages
owned by those managers; review the other observation files and migrate
portable commands to the appropriate declarative owner. Retain a mise task
only when the original package manager has required installation semantics
that Reseed does not model.

This ordering reserves room for additional platforms and managers without
requiring a generic provider abstraction. A new integration is a focused
module exposing status, restore, update, reconcile, and verify operations; it
is then inserted into the explicit workflow stage where its dependencies are
available.

### Homebrew mirror environment

When Homebrew cannot reach GitHub, set `software.homebrew.env` to a record of
environment variables applied to every `brew` invocation the engine runs
(restore, update, verify, backup, and reconcile). The USTC mirror, for
example:

```nuon
homebrew: {
  enabled: true
  manifests: [packages/macos/Brewfile]
  env: {
    "HOMEBREW_API_DOMAIN": "https://mirrors.ustc.edu.cn/homebrew-bottles/api"
    "HOMEBREW_BOTTLE_DOMAIN": "https://mirrors.ustc.edu.cn/homebrew-bottles"
    "HOMEBREW_BREW_GIT_REMOTE": "https://mirrors.ustc.edu.cn/brew.git"
    "HOMEBREW_CORE_GIT_REMOTE": "https://mirrors.ustc.edu.cn/homebrew-core.git"
    "HOMEBREW_CASK_GIT_REMOTE": "https://mirrors.ustc.edu.cn/homebrew-cask.git"
  }
}
```

The engine never modifies Homebrew's own configuration; it only passes the
environment per command, so removing the block restores official sources.

To keep the mirror active in interactive shells (outside Reseed), every
`reseed restore` and `reseed update` also regenerates snippets from this
environment: `reseed-homebrew-env.nu` in the Nushell vendor autoload and
`reseed-homebrew-env.fish` in `~/.config/fish/conf.d/` are loaded
automatically by their shells, while
`~/.local/share/reseed/shell/reseed-homebrew-env.sh` (POSIX) and
`reseed-homebrew-env.ps1` (PowerShell) are sourced from a profile. Removing
the `env` block deletes the snippets on the next run. A fresh `bootstrap.sh
--homebrew-mirror` install prints the same variables as profile exports for
the time before the first restore.

### Mise tool entries

The `[tools]` table is a mise manifest. Each key is a mise tool or a
backend-qualified package, and each value is a version or version list:

```toml
[tools]
node = "latest"
python = "latest"
rust = ["stable", "nightly"]
starship = "latest"
"aqua:pnpm/pnpm" = "latest"
"aqua:astral-sh/uv" = "latest"
"aqua:cargo-bins/cargo-binstall" = "latest"
"npm:opencode-ai" = "latest"
```

Use `[tools]` for runtimes and portable command-line tools that mise supports.
The backend prefix selects mise's installation backend; it is not an arbitrary
package name. A backend-qualified entry requires its runtime in the same
`[tools]` table: `npm:*` requires `node`, `cargo:*` requires `rust`, and
`pipx:*` requires `python`. Reseed installs those runtimes first, then the
complete mise configuration.

Leave a version unpinned for the latest release. Use an exact mise version when
reproducibility requires it. Do not put uv tools, pnpm globals, Yarn globals,
Bun globals, or individual Cargo binary crates in `[tools]`; use their manager
manifests instead. Cargo-binstall is the exception: it is a bootstrap tool
installed from a prebuilt binary (`aqua:cargo-bins/cargo-binstall`), never via
the `cargo:*` backend, so it does not depend on the Rust toolchain.

The example's `ruff` is declared in `packages/uv/tools.nuon`, and
`@biomejs/biome` is declared in `packages/node/pnpm/global.nuon`. Package
entries may be strings or records. Use a record when the installed package
must expose commands:

```nuon
{
  schema: 1
  packages: [
    {spec: "ruff" commands: [ruff]}
  ]
}
```

The manifests allow unversioned names for latest behavior and manager-native
pinned specs such as `ruff==0.12.0` or `@biomejs/biome@2.1.0`. Specifiers with
ranges, aliases, or other manager syntax are rejected during validation.
Reconcile matches package identity and checks versions only for pinned entries;
verification checks every declared command in the shared binary directory.

Do not move bootstrap dependencies into `[tools]`. The bootstrap scripts need
Git before they can clone or update private state, and Reseed needs Nushell,
mise, and chezmoi before the managed restore workflow can run. They are
engine-owned and are deliberately absent from platform desired manifests.
Node and configured Node package managers, along with uv, are shared mise
tools, not native platform packages. Enable Bun by adding its mise tool entry
and enabling the corresponding manager manifest. The Yarn integration requires
Yarn 1, which still ships the `yarn global` commands; pin it explicitly, for
example `yarn = "1.22.22"`.

Manager execution uses the selected `manager_config` and `mise exec`, so a
clean process does not need mise shims on its inherited `PATH`. uv and the
Node package managers write command shims to `~/.local/share/reseed/bin`; the
post-restore shell task generates the supported shell adapters for that
directory.

## Profiles

Profiles are recursive overlays on `config/recovery.nuon`. Later profiles win.
Records merge recursively and lists replace earlier lists. This makes package
manifest order and mise task order deterministic.

Mise configuration paths must be named `mise.toml` or
`mise.<environment>.toml`. Reseed maps the latter to mise's native `-E`
environment option instead of inventing its own tool-overlay semantics.

Use profiles for roles such as `personal`, `work`, or `studio`. Platform
selection is automatic, so a profile can be used on both Windows and macOS.

## Guided setup

The optional `setup` section drives `reseed setup`: which hosts receive the
SSH public key, the key comment, and the GPG key type. See the
[guided setup](setup.md) for the full configuration reference, admin allow
list semantics, and the wizard behavior.

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
