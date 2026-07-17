#!/bin/bash
# Run SwiftLint's type-aware analyzer rules (the `analyzer_rules` list in
# .swiftlint.yml: unused_import, unused_declaration, …) over Sources. These
# rules need every module's full compiler invocation, which
# llbuild_to_compile_commands.py recovers from SwiftPM's internal build
# manifest — so a debug build must exist and be current (`swift build`,
# `swift build --build-tests`, and `swift test` all produce one). If the
# manifest is missing, a plain debug build is run first; if it is merely
# stale, analysis sees the old file list, so build before analyzing.
# Not a pre-commit hook on purpose: it needs a full build.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MANIFEST="$ROOT/.build/debug.yaml"
DB="$ROOT/.build/compile_commands.json"

[ -f "$MANIFEST" ] || (cd "$ROOT" && swift build)
python3 "$ROOT/scripts/lint/llbuild_to_compile_commands.py" "$MANIFEST" "$DB"
cd "$ROOT"
swiftlint analyze --strict --quiet --compile-commands "$DB" Sources
echo "SwiftLint analyzer rules passed."
