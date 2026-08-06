# Private Reseed state

This directory is a chezmoi source and the private Git repository synchronized
between personal machines. The general Reseed engine is stored separately.

Keep dotfiles under `home/`, desired applications and package-manager manifests
under `packages/`, portable tools in `mise.toml`, and machine/role differences
in `config/profiles/`. Bootstrap tools are installed by the engine and do not
belong in platform manifests. Shared runtimes and portable tools belong in
mise `[tools]`; Cargo binaries belong in `packages/cargo/`, uv tools in
`packages/uv/`, and Node package-manager globals in the sibling manifests
under `packages/node/`.
Never commit raw credentials or generated caches.
