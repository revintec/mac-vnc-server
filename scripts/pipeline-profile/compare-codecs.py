#!/usr/bin/env python3
"""Build a disposable copy, compare the encoders, and verify decoded pixels.

Usage: python3 scripts/pipeline-profile/compare-codecs.py OUTPUT_DIRECTORY
The directory must not already exist. No server listener or UI is started.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

source = Path(__file__).resolve().parents[2]
root = Path(sys.argv[1]).resolve()
if root.is_relative_to(source) and not root.is_relative_to(source / '.build'):
    raise SystemExit('Choose a directory outside the repository or under .build to avoid copying the output into itself')
root.mkdir(parents=True, exist_ok=False)
server = root / 'server'
shutil.copytree(source, server, ignore=shutil.ignore_patterns('.build', '.git', '__pycache__'))
shutil.copy2(source / 'scripts/pipeline-profile/compare-codecs.swift',
             server / 'Sources/mac-vnc-server/CodecComparison.swift')
entry = server / 'Sources/mac-vnc-server/Main.swift'
text = entry.read_text()
anchor = '            let command = try CLI.parse'
if text.count(anchor) != 1:
    raise SystemExit('Main.swift entry point changed; refusing an unverified replacement')
entry.write_text(text.replace(anchor,
    '            if let output = ProcessInfo.processInfo.environment["MAC_VNC_CODEC_COMPARE"] '
    '{ try CodecComparison.run(output: output); return }\n' + anchor))
manifest = {str(p.relative_to(source)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted((source / 'Sources').rglob('*'))
            if p.suffix in {'.swift', '.c', '.h', '.inc'}}
(root / 'source-sha256.json').write_text(json.dumps(manifest, indent=2) + '\n')
with (root / 'build.log').open('w') as log:
    subprocess.run(['swift', 'build', '-c', 'release', '--package-path', str(server)],
                   stdout=log, stderr=subprocess.STDOUT, check=True)
with (root / 'run.log').open('w') as log:
    subprocess.run([str(server / '.build/release/mac-vnc-server-dev')],
                   env=dict(os.environ, MAC_VNC_CODEC_COMPARE=str(root / 'results')),
                   stdout=log, stderr=subprocess.STDOUT, check=True)
subprocess.run([sys.executable, str(source / 'scripts/pipeline-profile/analyze-codecs.py'),
                str(root / 'results')], check=True)
