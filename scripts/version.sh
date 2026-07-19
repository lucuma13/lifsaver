#!/bin/bash
# Print the lifsaver version parsed from Version.swift — the single source of
# truth shared by every packaging script and workflow. Fails loudly when the
# declaration stops matching the pattern, so an empty version can never leak
# silently into an artifact name or a pkg manifest.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

VERSION="$(sed -n 's/^public let lifsaverVersion = "\(.*\)"$/\1/p' "$ROOT/Sources/LifsaverKit/Version.swift")"
[ -n "$VERSION" ] || {
  echo "ERROR: could not read version from Version.swift" >&2
  exit 1
}
printf '%s\n' "$VERSION"
