#!/usr/bin/env python3
"""Reproduce the pinned zlib-ng subset from a locally downloaded source archive.

Usage: python3 scripts/vendor-zlib-ng.py /path/to/zlib-ng-2.3.3.tar.gz [--check]
Archive: https://github.com/zlib-ng/zlib-ng/archive/refs/tags/2.3.3.tar.gz
"""
import argparse
import hashlib
from pathlib import Path
import re
import tarfile

SHA256 = "92c0dd38b1548debf6c4b2d7b5aa16e4416ce5df6ddd405fa96431eb7aaa4a09"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("archive", type=Path)
parser.add_argument("--check", action="store_true")
args = parser.parse_args()
if hashlib.sha256(args.archive.read_bytes()).hexdigest() != SHA256:
    raise SystemExit("Source archive does not match the pinned SHA-256")
with tarfile.open(args.archive) as archive:
    source = {}
    for member in archive.getmembers():
        if member.isfile():
            name = member.name.split("/", 1)[1]
            source[name] = archive.extractfile(member).read()

make = source["Makefile.in"].decode().split("OBJZ =", 1)[1].split("OBJG =", 1)[0]
selected = {name.replace(".o", ".c") for name in re.findall(r"[\w/]+\.o", make)}
selected.update("arch/arm/" + name + ".c" for name in [
    "arm_features", "adler32_neon", "chunkset_neon", "compare256_neon", "slide_hash_neon", "crc32_armv8"
])
selected.update(name for name in source if name.endswith(".h") and (
    "/" not in name or name.startswith(("arch/generic/", "arch/arm/"))
))
selected.add("LICENSE.md")
output = {name: source[name] for name in selected}
for stem in ["zlib-ng", "zconf-ng"]:
    output[stem + ".h"] = source[stem + ".h.in"]
output["zlib_name_mangling-ng.h"] = source["zlib_name_mangling.h.empty"]

destination = Path(__file__).resolve().parents[1] / "Sources/CVNCZlib/vendor"
existing = {str(path.relative_to(destination)) for path in destination.rglob("*") if path.is_file()}
unexpected = existing - output.keys()
if unexpected:
    raise SystemExit(f"Unexpected vendor files; review before removing: {sorted(unexpected)}")
for name, data in sorted(output.items()):
    target = destination / name
    if args.check:
        if not target.exists() or target.read_bytes() != data:
            raise SystemExit(f"Vendor mismatch: {name}")
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
print(f"{'Verified' if args.check else 'Wrote'} {len(output)} pinned upstream files")
