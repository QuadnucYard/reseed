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
├── packages/             native and manager manifests
├── scripts/              private idempotent restore tasks
└── mise.toml             shared runtimes and portable tools
```

## Tool ownership

Reseed has three software ownership layers:

- The engine bootstrap contract owns Git, chezmoi, Nushell, and mise. The
  platform bootstrap scripts install these through WinGet or Homebrew, and
  private native manifests must not list them.
- Shared mise `[tools]` owns runtimes and portable tools that are common to
  platforms. The shared configuration uses Node, explicit Aqua pnpm and uv,
  Cargo-binstall, Starship, and the configured npm tool.
- Manager manifests own packages whose installation semantics belong to a
  package manager: Cargo binaries in `packages/cargo/binstall.nuon`, uv tools
  in `packages/uv/tools.nuon`, and Node package-manager globals in the sibling
  manifests under `packages/node/` for pnpm, Yarn, and Bun.

WinGet and Homebrew manifests contain only curated platform-specific software.
Kopia can optionally snapshot narrow opaque application state. The restore
order is bootstrap preflight, native packages, mise tools, manager manifests,
shell adapters, chezmoi, snapshots, and verification.

The shared manager binary directory is `~/.local/share/reseed/bin`. It is
ignored by the private repository. The `reseed:shells` task generates Nushell
and Fish automatic adapters plus PowerShell and POSIX profile snippets after
the managed tools are installed.

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

## Guided setup

`reseed setup` walks through user identity, SSH keys, GitHub uploads, and
commit signing. The full wizard covers everything; per-purpose subcommands
run one area at a time:

```powershell
nu reseed.nu setup
nu reseed.nu setup ssh
nu reseed.nu setup gh
nu reseed.nu setup gpg
```

Every run prints a dependency-ordered plan, skips steps that are already
satisfied, and ends with a pass/fail summary. jj and GPG are optional features
that default to on (`--no-jj`, `--no-gpg`). See the [guided setup](docs/setup.md)
for purposes, host configuration, and security notes.

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

When the network cannot reach GitHub (common in China), Homebrew bootstrap
accepts `--homebrew-mirror ustc|tuna` to route the installer and package
downloads through a China mirror, or `--brew-install-url URL` to point at a
specific installer script. The installer download and its execution are
bounded by timeouts, and a non-interactive install that needs an admin
password retries interactively. Homebrew package downloads during later
`reseed restore` runs use the mirrors configured in the private state's
`software.homebrew.env` (see [customizing](docs/customizing.md)).

The configured mirror is also persisted for interactive shells: every
`reseed restore` and `reseed update` regenerates shell snippets that export
the same environment. Nushell and Fish load them automatically; POSIX and
PowerShell users source `~/.local/share/reseed/shell/reseed-homebrew-env.sh`
(or `.ps1`) from their profile, exactly like the managed-tools adapters.

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
payloads come only from the private state's `bundle.paths`. Offline recovery
still requires the bootstrap contract's Git, chezmoi, and Nushell tools.
Normal software recovery additionally requires mise; offline recovery uses
`--skip-software`.

## Secrets

Do not commit passwords, tokens, recovery codes, private SSH/GPG keys, browser
profiles, or whole AppData/Library trees. Keep secret values in a password
manager, Windows Credential Manager, macOS Keychain, or chezmoi's encrypted
and password-manager integrations. Kopia repository credentials must remain
external to both repositories.

See [recovery](docs/recovery.md) for stage ordering and resume behavior.

## Engine internals

- [lib/README.md](lib/README.md) — the core library: configuration loading and
  validation, Git operations, checkpoints, manager plumbing, and the workflow
  orchestration layer.
- [integrations/README.md](integrations/README.md) — the per-tool integration
  contract (status/restore/update/reconcile/verify/backup) and how to add a new
  integration.
- [customizing](docs/customizing.md) and [backup inventory](docs/backup-inventory.md)
  describe the private state format and daily capture behavior.
- [guided setup](docs/setup.md) documents the setup wizard, its purposes, and
  the `setup` configuration section.
