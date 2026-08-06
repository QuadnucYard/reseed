# Reseed

Reseed restores Windows and macOS workstations by coordinating mature native
tools. This repository is the reusable engine. Personal configuration belongs
in a separate private state repository.

| Location | Purpose | Synced where |
| --- | --- | --- |
| Reseed engine | CLI, bootstraps, integrations, tests, state template | General engine remote |
| `~/.local/share/reseed` | Dotfiles, package manifests, profiles, mise tools | Your private Git remote |
| `~/.local/state/reseed` | Observations and restore checkpoints | Nowhere; disposable local state |

On this Windows machine, the private state path resolves to
`C:\Users\dell\.local\share\reseed`. Set `RESEED_STATE_ROOT` or pass
`--state-root` to use another path.

## Private state

`reseed init` copies the generic scaffold from `templates/state/` into the
private location and runs `git init -b main`. It refuses a nonempty directory
without the `.reseed-state` sentinel.

```powershell
# Initialize local private state. This is safe to run again.
nu reseed.nu init

# Attach a private remote you created on your Git host.
nu reseed.nu init --remote-url <private-state-git-url>

# Capture, commit, and push the private state.
nu reseed.nu backup --commit --push
```

The engine never chooses a hosting provider or remote URL. It also refuses to
replace an existing `origin` with a different URL.

The private repository contains all desired workstation state:

```text
~/.local/share/reseed/
├── .chezmoiroot          points chezmoi at home/
├── config/               recovery policy and profile overlays
├── home/                 private chezmoi source files
├── packages/             native manifests and cargo-binstall packages
├── scripts/              private idempotent restore tasks
└── mise.toml             shared runtimes and portable tools
```

## Tool ownership

- chezmoi owns dotfiles and selected user configuration.
- WinGet owns Windows applications.
- Homebrew Bundle owns macOS applications.
- mise owns portable runtimes and developer tools.
- Kopia can optionally snapshot narrow opaque application state.

The starter state installs Git, chezmoi, Nushell, and mise on Windows. On
macOS it also installs Fish. Mise then installs Rust stable, Rust nightly,
Starship, and the configured Cargo-binstall bootstrap on both platforms.
Native packages run before mise; Cargo-binstall packages, shell setup, and
chezmoi run afterwards.

Starship uses one private `~/.config/starship.toml` for every shell. Fish has a
small `conf.d` adapter. The `reseed:shells` mise task generates Nushell's
platform-specific Starship autoload file after Starship is installed.

## Daily commands

These use the default private state path:

```sh
nu reseed.nu plan --profiles personal
nu reseed.nu status --profiles personal
nu reseed.nu backup --profiles personal
nu reseed.nu reconcile --profiles personal
nu reseed.nu restore --profiles personal
nu reseed.nu update --profiles personal
nu reseed.nu verify --profiles personal
nu reseed.nu bundle --output reseed-source.tar.gz
```

Use `--dry-run` to print commands, `--yes` for unattended restore/update,
`--resume` after an interrupted restore, and `--skip-software` for an offline
configuration-only restore. Every command accepts `--state-root`.

`backup` captures chezmoi changes and writes package-manager observations under
the disposable state directory. Observations are not automatically promoted.
Only entries deliberately kept in the private WinGet manifest, Brewfile,
`mise.toml`, or restore tasks are synchronized. Removing an entry stops future
restore/update management but does not uninstall it locally.

Avoid `backup --refresh-manifests` during routine backups. That option
deliberately replaces a curated native manifest with the full machine export.

## Add dotfiles

Run chezmoi against the private source, not this engine repository:

```sh
chezmoi --source ~/.local/share/reseed add ~/.gitconfig
chezmoi --source ~/.local/share/reseed add ~/.config/starship.toml
chezmoi --source ~/.local/share/reseed diff
```

Nushell's entry files are under `%APPDATA%\nushell` on Windows and
`~/Library/Application Support/nushell` on macOS. Review environment files for
tokens before adding them. See [customizing](docs/customizing.md) and the
[backup inventory](docs/backup-inventory.md).

## New machine

First obtain this general engine repository. Then let its bootstrap install the
small native dependency chain and clone the private state repository.

Windows PowerShell:

```powershell
.\bootstrap.ps1 -StateRepository <private-state-git-url> -Profiles personal
```

macOS:

```sh
./bootstrap.sh --state-repository <private-state-git-url> --profiles personal
```

The older `-Repository`/`--repository` spelling remains an alias for the private
state repository. Credentials for cloning must already be available through
SSH, a credential manager, or an interactive Git helper.

## Offline recovery

Bundles contain separate committed `engine/` and `state/` snapshots plus
platform bootstrap executables and checksums. After extraction:

```powershell
.\reseed\engine\bootstrap.ps1 -Offline -StateRoot ..\state
```

```sh
./reseed/engine/bootstrap.sh --offline --state-root ../state
```

Ignored and untracked files are excluded from both Git snapshots. Optional
payloads come only from the private state's `bundle.paths`.

## Secrets

Do not commit passwords, tokens, recovery codes, private SSH/GPG keys, browser
profiles, or whole AppData/Library trees. Keep secret values in a password
manager, Windows Credential Manager, macOS Keychain, or chezmoi's encrypted
and password-manager integrations. Kopia repository credentials must remain
external to both repositories.

See [recovery](docs/recovery.md) for stage ordering and resume behavior.
