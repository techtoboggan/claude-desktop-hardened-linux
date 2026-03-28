"""Shared utilities for Cowork patches."""

import os
import json


def find_main_entry(asar_dir):
    """Find the main JavaScript entry point in the asar contents."""
    candidates = [
        os.path.join(asar_dir, '.vite', 'build', 'index.js'),
        os.path.join(asar_dir, '.vite', 'build', 'main.js'),
        os.path.join(asar_dir, 'index.js'),
        os.path.join(asar_dir, 'main.js'),
    ]

    for c in candidates:
        if os.path.exists(c):
            return c

    for root, dirs, files in os.walk(os.path.join(asar_dir, '.vite')):
        for f in files:
            if f in ('index.js', 'main.js'):
                return os.path.join(root, f)

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
