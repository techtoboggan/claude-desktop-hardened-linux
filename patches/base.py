"""Shared utilities for Cowork patches."""

import os
import re
import json


# A thin loader entry (see _resolve_loader_chunk) is only a few KB. Anything
# larger is assumed to be a monolithic bundle that holds the code itself.
_THIN_LOADER_MAX_BYTES = 100_000


def _resolve_loader_chunk(entry_path):
    """If *entry_path* is a thin Vite loader, return its real code chunk.

    Since upstream 1.13576.0 the main-process bundle is split: `.vite/build/
    index.js` is now a ~800-byte loader whose only job is to
    `require("./index.chunk-<hash>.js")` (plus a few node built-ins). All the
    code our patches target moved into that sibling chunk. The chunk hash
    changes every release, so we discover it by parsing the loader's relative
    requires and returning the largest resolved sibling (the main chunk dwarfs
    any other — ~4.5 MB vs the loader's <1 KB).

    Returns *entry_path* unchanged for old monolithic bundles (no thin loader,
    or no resolvable relative require).
    """
    try:
        size = os.path.getsize(entry_path)
    except OSError:
        return entry_path
    if size > _THIN_LOADER_MAX_BYTES:
        return entry_path  # monolithic bundle: code lives here

    with open(entry_path, 'r', encoding='utf-8') as f:
        loader = f.read()

    entry_dir = os.path.dirname(entry_path)
    siblings = []
    for rel in re.findall(r'require\((?:"|\')(\./[^"\']+\.js)(?:"|\')\)', loader):
        cand = os.path.normpath(os.path.join(entry_dir, rel))
        if os.path.isfile(cand):
            siblings.append(cand)

    if not siblings:
        return entry_path

    return max(siblings, key=os.path.getsize)


def find_main_entry(asar_dir):
    """Find the main JavaScript entry point in the asar contents.

    Resolves a thin Vite loader to its real code chunk (see
    _resolve_loader_chunk) so patches run against the file that actually
    contains the main-process code.
    """
    candidates = [
        os.path.join(asar_dir, '.vite', 'build', 'index.js'),
        os.path.join(asar_dir, '.vite', 'build', 'main.js'),
        os.path.join(asar_dir, 'index.js'),
        os.path.join(asar_dir, 'main.js'),
    ]

    for c in candidates:
        if os.path.exists(c):
            return _resolve_loader_chunk(c)

    for root, dirs, files in os.walk(os.path.join(asar_dir, '.vite')):
        for f in files:
            if f in ('index.js', 'main.js'):
                return _resolve_loader_chunk(os.path.join(root, f))

    return None


def find_brace_block(content, start):
    """Find the end of a brace-delimited block starting at the first '{' after *start*."""
    brace_start = content.index('{', start)
    depth = 0
    for i in range(brace_start, min(brace_start + 5000, len(content))):
        if content[i] == '{':
            depth += 1
        elif content[i] == '}':
            depth -= 1
            if depth == 0:
                return i + 1
    return None


def create_package_json_entry(asar_dir):
    """Ensure package.json lists our stub modules."""
    pkg_path = os.path.join(asar_dir, 'package.json')
    if not os.path.exists(pkg_path):
        return

    try:
        with open(pkg_path, 'r') as f:
            pkg = json.load(f)

        if 'dependencies' not in pkg:
            pkg['dependencies'] = {}

        pkg['dependencies']['cowork'] = 'file:./node_modules/cowork'
        swift_at_scope = os.path.isdir(
            os.path.join(asar_dir, 'node_modules', '@ant', 'claude-swift')
        )
        if swift_at_scope:
            pkg['dependencies']['@ant/claude-swift'] = 'file:./node_modules/@ant/claude-swift'
        else:
            pkg['dependencies']['claude-swift-stub'] = 'file:./node_modules/claude-swift-stub'

        with open(pkg_path, 'w') as f:
            json.dump(pkg, f, indent=2)

        print('  [ok] Updated package.json with cowork dependencies')
    except Exception as e:
        print(f'  [warn] Could not update package.json: {e}')
