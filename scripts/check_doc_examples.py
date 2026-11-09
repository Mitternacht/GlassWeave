#!/usr/bin/env python3
"""Checks that every Swift example in the DocC catalog is compiled by the tests.

Each ```swift block in Sources/GlassWeave/GlassWeave.docc/GlassWeave.md must
appear verbatim in one of the DocumentationExamples.swift files under Tests/,
which the package's test targets compile and run. Exits non-zero, naming the
first line of each missing block, when one does not.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Sources/GlassWeave/GlassWeave.docc/GlassWeave.md"
MIRRORS = sorted(ROOT.glob("Tests/*/DocumentationExamples.swift"))


def main() -> int:
    blocks = re.findall(r"```swift\n(.*?)```", CATALOG.read_text(), flags=re.DOTALL)
    if not blocks:
        print(f"No Swift examples found in {CATALOG.relative_to(ROOT)}")
        return 1
    compiled = "\n".join(path.read_text() for path in MIRRORS)
    missing = [block for block in blocks if block not in compiled]
    for block in missing:
        first = next(line for line in block.splitlines() if line.strip())
        print(f"Not compiled by any DocumentationExamples.swift: example starting {first!r}")
    print(f"{len(blocks) - len(missing)} of {len(blocks)} catalog examples are compiled by the tests")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
