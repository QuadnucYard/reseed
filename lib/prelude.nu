# Shared module prelude for consumers (integrations and tests).
#
# Re-exports the commonly needed definitions from the leaf lib modules so a
# consumer needs one import instead of five selective ones:
#
#   use ../lib/prelude.nu *
#
# Orchestrator modules (config.nu, git.nu, workflow.nu) are intentionally not
# included: they depend on the leaf modules, so importing them here would
# create an import cycle, and their names are specific enough that importing
# them explicitly reads better. Never add a name to any lib module that
# collides with another name already re-exported here.
export use core.nu *
export use manager_core.nu *
export use managed_tools.nu *
export use mise.nu *
export use state.nu *
