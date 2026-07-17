#!/bin/bash
# Run SwiftLint's type-aware analyzer rules (the `analyzer_rules` list in
# .swiftlint.yml: unused_import, unused_declaration, …) over Sources. These
# rules need every module's full compiler invocation, which
# llbuild_to_compile_commands.py recovers from SwiftPM's internal build
# manifest — so a debug build is run first to keep it current (a stale
# manifest would hand analysis an old file list; when nothing changed the
# build is a ~0.3s no-op).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MANIFEST="$ROOT/.build/debug.yaml"
DB="$ROOT/.build/compile_commands.json"

(cd "$ROOT" && swift build)
python3 "$ROOT/scripts/lint/llbuild_to_compile_commands.py" "$MANIFEST" "$DB"
cd "$ROOT"
swiftlint analyze --strict --quiet --compile-commands "$DB" Sources
echo "SwiftLint analyzer rules passed."
