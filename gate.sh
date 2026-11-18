#!/bin/sh
# The gate: what must pass before anything lands. factorium.toml runs it
# as both the fast and the slow gate.
# It generates the project with the pinned XcodeGen and runs every test.
# Tests build unsigned (CODE_SIGNING_ALLOWED: NO in project.yml), so no
# signing identity is needed here.
set -eu
cd "$(dirname "$0")"
# Every ADR has its own number (mytokens#5).
tools/adr-numbers.sh
exec make test
