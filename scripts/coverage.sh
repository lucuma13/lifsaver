#!/bin/bash
# Report code coverage for the built xctest bundles, and export it as LCOV -
# the single source of coverage truth shared by `make test` and CI. Both read
# the same profile through the same filter, so the table printed locally can
# never describe a different set of files from the number Codecov publishes.
#
# Prints the human-readable table to stdout and writes coverage.lcov for
# upload; CI runs this script and uploads the file.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# SwiftPM's own answer for where the build landed. Searching .build by hand
# instead can turn up a stale profile or bundle from an earlier configuration
# and report it as current.
BIN="$(swift build --show-bin-path)"
PROF="$BIN/codecov/default.profdata"
LCOV="coverage.lcov"
# Anchored on the separator, so only the Tests/ and .build/ directories drop
# out - an unanchored 'Tests' would also swallow sources merely named for them.
IGNORE='(Tests|\.build)/'

if [ ! -f "$PROF" ]; then
  echo "error: no coverage profile at $PROF" >&2
  echo "       run: swift test --enable-code-coverage" >&2
  exit 1
fi

# A .xctest bundle wraps the binary; deriving its name beats hardcoding the
# package's, which silently breaks the day the package is renamed.
bundles=()
for bundle in "$BIN"/*.xctest; do
  [ -e "$bundle" ] || continue
  [ -d "$bundle" ] && bundle="$bundle/Contents/MacOS/$(basename "$bundle" .xctest)"
  bundles+=("$bundle")
done
if [ ${#bundles[@]} -eq 0 ]; then
  echo "error: no .xctest bundle in $BIN" >&2
  exit 1
fi

# llvm-cov takes one binary positionally; the rest arrive as -object, which is
# what merges them into one report instead of several disjoint ones.
objects=("${bundles[0]}")
for bundle in "${bundles[@]:1}"; do
  objects+=(-object "$bundle")
done

# xcrun picks the active toolchain's llvm-cov; fall back to one already on PATH.
cov() {
  xcrun llvm-cov "$@" || llvm-cov "$@"
}

cov report "${objects[@]}" -instr-profile="$PROF" -ignore-filename-regex="$IGNORE"
cov export -format=lcov "${objects[@]}" -instr-profile="$PROF" \
  -ignore-filename-regex="$IGNORE" >"$LCOV"
