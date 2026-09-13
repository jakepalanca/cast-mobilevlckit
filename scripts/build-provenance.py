#!/usr/bin/env python3
"""Bind the installed framework to its build recipe, patches, and binaries."""
import argparse
import hashlib
import json
from pathlib import Path


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def provenance(repo, output):
    inputs = [repo / "UPSTREAM.lock", repo / "scripts/build-mobilevlckit-with-livehttp.sh",
              repo / "scripts/build-provenance.py", *sorted((repo / "patches").glob("*.patch"))]
    binaries = [output / "MobileVLCKit.xcframework" / arch / "MobileVLCKit.framework/MobileVLCKit"
                for arch in ("ios-arm64", "ios-arm64-simulator")]
    return {"schema": 1,
            "inputs": {str(p.relative_to(repo)): digest(p) for p in inputs},
            "binaries": {str(p.relative_to(output)): digest(p) for p in binaries}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--record", action="store_true")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    stamp = args.output / "cast-build-provenance.json"
    try:
        current = provenance(repo, args.output)
        if args.record:
            temporary = stamp.with_suffix(".tmp")
            temporary.write_text(json.dumps(current, indent=2) + "\n")
            temporary.replace(stamp)
        elif json.loads(stamp.read_text()) != current:
            raise ValueError("framework does not match the current build recipe or patches")
    except (OSError, ValueError) as error:
        print(f"[build-mvk] Provenance check failed: {error}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
