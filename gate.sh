#!/bin/sh
# The gate: what must pass before anything lands. docs/agents/afkconvoy.md
# names it as `gate_command`, run through `afkconvoy exclusive`.
# It generates the project with the pinned XcodeGen and runs every test.
# Tests build unsigned (CODE_SIGNING_ALLOWED: NO in project.yml), so no
# signing identity is needed here.
set -eu
cd "$(dirname "$0")"
exec make test
