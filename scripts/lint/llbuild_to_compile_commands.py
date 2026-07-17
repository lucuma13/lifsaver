#!/usr/bin/env python3
"""Convert SwiftPM's llbuild manifest (.build/debug.yaml) into a clang-style
compilation database for `swiftlint analyze`.

SwiftPM never exports the compilation database analyzer rules need, but its
internal llbuild manifest records every module as a `"C.<name>.module":` shell
node whose `inputs:` list the module's source files and whose `args:` hold the
full swiftc invocation. SwiftLint wants one database entry per source file
with the module's complete compiler arguments: the compiler executable
dropped, `@response-file` arguments expanded, and driver-only flags SourceKit
rejects removed.

Dependency modules checked out under .build/ are skipped, as are test
targets — sourcekitd crashes expanding the swift-testing @Suite/@Test macros
during analysis. The manifest format is SwiftPM-internal: if a toolchain
update changes it, this script fails loudly (no entries), never silently.
"""
import json
import os
import re
import sys

manifest_path, output_path = sys.argv[1], sys.argv[2]
repo_root = os.path.dirname(os.path.dirname(os.path.abspath(manifest_path)))
with open(manifest_path) as fh:
    text = fh.read()

# driver-only or analysis-hostile flags; True = flag consumes a value
DROPPED_FLAGS = {
    "-incremental": False,
    "-parseable-output": False,
    "-serialize-diagnostics": False,
    "-emit-dependencies": False,
    "-c": False,
    "-output-file-map": True,
    "-index-store-path": True,
    "-profile-generate": False,
    "-profile-coverage-mapping": False,
}


def clean_arguments(arguments):
    cleaned = []
    skip_next = False
    for arg in arguments[1:]:  # drop the swiftc executable itself
        if skip_next:
            skip_next = False
            continue
        if arg in DROPPED_FLAGS:
            skip_next = DROPPED_FLAGS[arg]
            continue
        if arg.startswith("-j") and arg[2:].isdigit():
            continue
        if arg.startswith("@") and os.path.isfile(arg[1:]):
            with open(arg[1:]) as rsp:
                cleaned.extend(line.strip() for line in rsp if line.strip())
            continue
        cleaned.append(arg)
    return cleaned


entries = []
build_dir = os.path.join(repo_root, ".build")
tests_dir = os.path.join(repo_root, "Tests")
for block in re.split(r"\n(?=  \")", text):
    if not re.match(r'^  "C\.[^"]*\.module":', block):
        continue
    inputs = re.search(r"^    inputs: (\[.*\])$", block, re.M)
    args = re.search(r"^    args: (\[.*\])$", block, re.M)
    if not (inputs and args):
        continue
    sources = [s for s in json.loads(inputs.group(1)) if s.endswith(".swift")]
    if not sources or any(
        not s.startswith(repo_root + os.sep)
        or s.startswith(build_dir + os.sep)
        or s.startswith(tests_dir + os.sep)
        for s in sources
    ):
        continue
    arguments = clean_arguments(json.loads(args.group(1)))
    for source in sources:
        entries.append(
            {"directory": repo_root, "file": source, "arguments": arguments}
        )

if not entries:
    sys.exit(f"ERROR: no Swift compile commands found in {manifest_path}")

with open(output_path, "w") as fh:
    json.dump(entries, fh, indent=1)
print(f"wrote {len(entries)} entries to {output_path}")
