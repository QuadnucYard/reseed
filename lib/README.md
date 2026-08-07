# lib

The engine's core library. `reseed.nu` is the thin command-line facade; every
workflow it exposes delegates to `workflow.nu`, which composes these modules.
All functions are documented in Nushell's help syntax: `nu -c "use lib/core.nu *; help run-command"`.

Dependency direction runs from low-level utilities up to orchestration:

```text
core → managed_tools → manager_core → mise → config → git → state → workflow
```

`setup.nu` is a separate facade for the guided setup wizard (identity, SSH
keys, GitHub uploads, and GPG signing); the implementation lives in the
`setup/` submodules (plan, shared, common, ssh, gpg), which import only
`core.nu`, and the facade is called directly from `reseed.nu`, outside the
recovery workflows.
