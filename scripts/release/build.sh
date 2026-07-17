#!/bin/bash
# Build universal (arm64 + x86_64) release binaries for the app and CLI.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

swift build -c release --arch arm64
swift build -c release --arch x86_64

OUT="$ROOT/.build/universal-release"
mkdir -p "$OUT"
for product in lifsaver LifsaverApp; do
  lipo -create \
    ".build/arm64-apple-macosx/release/$product" \
    ".build/x86_64-apple-macosx/release/$product" \
    -output "$OUT/$product"
  printf '%s: ' "$product"
  lipo -archs "$OUT/$product"
done

echo "Products: $OUT"
