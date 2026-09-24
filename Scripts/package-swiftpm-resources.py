#!/usr/bin/env python3
"""Relink SwiftPM resource accessors for a standard signed macOS app layout.

Only generated build files are changed; dependency checkouts stay untouched.
Replay the compiler/linker argument arrays emitted by this SwiftPM build.
"""
import json
from pathlib import Path
import subprocess

commands = {}
key = None
for line in Path('.build/release.yaml').read_text().splitlines():
    if line.startswith('  "') and line.endswith(':'):
        key = json.loads(line.strip()[:-1])
    elif line.startswith('    args: '):
        commands[key] = json.loads(line.split('args: ', 1)[1])

build = Path('.build/release').resolve()
link = next(v for k, v in commands.items()
            if k.startswith('C.BlazingFastTranscription-') and k.endswith('.exe'))
objects = (build / 'BlazingFastTranscription.product/Objects.LinkFileList').read_text()
for accessor in sorted(build.glob('*.build/DerivedSources/resource_bundle_accessor.swift')):
    target = accessor.parent.parent.name.removesuffix('.build')
    if str(accessor.parent.parent) not in objects:
        continue
    original = accessor.read_text()
    accessor.write_text(original.replace('Bundle.main.bundleURL.appendingPathComponent',
        '(Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent'))
    command = next(v for k, v in commands.items()
                   if k.startswith(f'C.{target}-') and k.endswith('.module'))
    print(f'Packaging resources: {target}', flush=True)
    subprocess.run(command, check=True)
subprocess.run(link, check=True)
