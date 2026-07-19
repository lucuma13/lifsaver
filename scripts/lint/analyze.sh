#!/bin/bash
# Run SwiftLint's type-aware analyzer rules (the `analyzer_rules` list in
# .swiftlint.yml: unused_import, unused_declaration, …) over Sources. These
# rules need every module's full swiftc invocation.
#
# SwiftPM never exports the compile_commands.json analyzers want, but its
# internal llbuild manifest (.build/debug.yaml) records each module as a
# "C.<name>.module" node whose `inputs:` list the sources and `args:` hold the
# swiftc invocation. We rebuild a compilation database from it: one entry per
# source carrying the module's args, with the compiler dropped, @response-files
# expanded, and driver-only flags SourceKit rejects removed. Dependency modules
# (under .build/) and test targets (under Tests/) are skipped — sourcekitd
# crashes expanding the swift-testing @Suite/@Test macros during analysis.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MANIFEST="$ROOT/.build/debug.yaml"
DB="$ROOT/.build/compile_commands.json"

cd "$ROOT"
swift build

# Flags SourceKit rejects. The DROP_VALUE ones also consume the following arg.
DROP_VALUE='["-output-file-map","-index-store-path"]'
DROP_FLAG='["-incremental","-parseable-output","-serialize-diagnostics","-emit-dependencies","-c","-profile-generate","-profile-coverage-mapping"]'

ENTRIES="$(mktemp)"
trap 'rm -f "$ENTRIES"' EXIT

# Emit "<inputs-json>\t<args-json>" for each C.<name>.module node.
awk '
  /^  "C\.[^"]*\.module":/ { inmod = 1; ins = ""; next }
  /^  "/ && inmod          { inmod = 0 }
  inmod && /^    inputs: /  { ins = substr($0, index($0, "[")) }
  inmod && /^    args: /    { print ins "\t" substr($0, index($0, "[")); inmod = 0 }
' "$MANIFEST" | while IFS=$'\t' read -r ins args; do
  # Keep the module only if every .swift source is first-party: under the
  # repo, and not under .build/ or Tests/ (skips dependencies and tests).
  keep="$(printf '%s' "$ins" | jq -r \
    --arg repo "$ROOT/" --arg build "$ROOT/.build/" --arg tests "$ROOT/Tests/" '
        [.[] | select(endswith(".swift"))] as $s
        | (($s | length) > 0)
          and all($s[]; startswith($repo) and (startswith($build) | not) and (startswith($tests) | not))')"
  [ "$keep" = "true" ] || continue

  # Clean the args: drop the swiftc executable, dropped flags (and any value
  # they consume), and -jN. @response tokens pass through for expansion below.
  cleaned=()
  while IFS= read -r a; do
    cleaned+=("$a")
  done < <(printf '%s' "$args" | jq -r --argjson dv "$DROP_VALUE" --argjson df "$DROP_FLAG" '
        .[1:]
        | reduce .[] as $a ([[], false];
            if   .[1]                      then [.[0], false]
            elif ($dv | index($a))         then [.[0], true]
            elif ($df | index($a))         then [.[0], false]
            elif ($a | test("^-j[0-9]+$")) then [.[0], false]
            else [(.[0] + [$a]), false] end)
        | .[0][]')

  # Expand @response-files inline (SwiftPM lists a module's sources this way).
  expanded=()
  for a in "${cleaned[@]}"; do
    if [ "${a:0:1}" = "@" ] && [ -f "${a#@}" ]; then
      while IFS= read -r line; do
        [ -n "$line" ] && expanded+=("$line")
      done <"${a#@}"
    else
      expanded+=("$a")
    fi
  done

  # One DB entry per .swift source, all sharing the module's cleaned args.
  # Build the args array with jq rather than --args, whose option parsing
  # chokes on values that start with '-' (e.g. -module-name).
  args_json="$(printf '%s\n' "${expanded[@]}" | jq -Rn '[inputs]')"
  printf '%s' "$ins" | jq -c --arg dir "$ROOT" --argjson args "$args_json" '
        [.[] | select(endswith(".swift"))][]
        | {directory: $dir, file: ., arguments: $args}' >>"$ENTRIES"
done

# Fail loudly rather than analyze an empty file list (the manifest being absent
# or its SwiftPM-internal format having changed).
[ -s "$ENTRIES" ] || {
  echo "ERROR: no Swift compile commands found in $MANIFEST" >&2
  exit 1
}
jq -s '.' "$ENTRIES" >"$DB"

swiftlint analyze --strict --quiet --compile-commands "$DB" Sources
echo "SwiftLint analyzer rules passed."
