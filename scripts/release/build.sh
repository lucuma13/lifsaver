#!/bin/bash
# Build the universal (arm64 + x86_64) release binary.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

swift build -c release --arch arm64
swift build -c release --arch x86_64

OUT="$ROOT/.build/universal-release"
mkdir -p "$OUT"
lipo -create \
  ".build/arm64-apple-macosx/release/Lifsaver" \
  ".build/x86_64-apple-macosx/release/Lifsaver" \
  -output "$OUT/Lifsaver"
printf 'Lifsaver: '
lipo -archs "$OUT/Lifsaver"

echo "Products: $OUT"
