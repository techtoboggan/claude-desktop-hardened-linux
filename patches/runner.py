"""Orchestrate all Cowork patches in sequence."""

import os
import subprocess
import sys

from .base import find_main_entry, create_package_json_entry
from . import patch_platform_gating
from . import patch_vm_manifest
from . import patch_platform_constants
from . import patch_enterprise_config
from . import patch_api_headers
from . import patch_binary_manager
from . import patch_binary_resolution
from . import patch_preload_paths
from . import inject_cowork_init

PATCHES = [
    ("Platform gating functions", patch_platform_gating),
    ("Preload script paths (asar→real filesystem)", patch_preload_paths),
    ("VM image manifest", patch_vm_manifest),
    ("Platform constants", patch_platform_constants),
    ("Enterprise config", patch_enterprise_config),
    ("API headers", patch_api_headers),
    ("Binary manager (getHostPlatform)", patch_binary_manager),
    ("Binary resolution (getLocalBinaryPath)", patch_binary_resolution),
    ("Cowork initialization", inject_cowork_init),
]


def run(asar_dir):
    """Apply all patches to the asar contents and return exit code."""
    print(f'[cowork-patcher] Patching: {asar_dir}')

    main_entry = find_main_entry(asar_dir)
    if not main_entry:
        print('Error: Could not find main JavaScript entry point')
        return 1

    print(f'  [found] Main entry: {main_entry}')

    with open(main_entry, 'r', encoding='utf-8') as f:
        content = f.read()

    original_size = len(content)
    success_count = 0
    total_patches = len(PATCHES)

    for i, (name, module) in enumerate(PATCHES, 1):
        print(f'  [patch {i}/{total_patches}] {name}...')
        result = module.apply(content)
        if isinstance(result, tuple):
            content, ok = result
        else:
            content = result
            ok = True
        if ok:
            success_count += 1

    with open(main_entry, 'w', encoding='utf-8') as f:
        f.write(content)

    print(f'  [ok] Patched {main_entry} ({original_size} -> {len(content)} bytes)')

    # Validate patched JS is syntactically valid
    try:
        result = subprocess.run(
            ['node', '--check', main_entry],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode == 0:
            print('  [ok] Post-patch syntax validation passed')
        else:
            print(f'  [FAIL] Patched JS has syntax errors:\n{result.stderr[:500]}')
            return 1
    except FileNotFoundError:
        print('  [warn] node not found — skipping syntax validation')
    except subprocess.TimeoutExpired:
        print('  [warn] Syntax validation timed out — skipping')

    create_package_json_entry(asar_dir)

    # Patch mainWindow.js preload: wrap getInitialLocale() in try-catch so
    # the preload survives the initial file:// page load before claude.ai loads.
    _patch_preload_locale(asar_dir)

    print(f'[cowork-patcher] Done! {success_count}/{total_patches} patches applied')

    if success_count < 3:
        print('[cowork-patcher] WARNING: Some critical patches failed -- Cowork may not activate')
        return 1

    return 0


def _patch_preload_locale(asar_dir):
    """Wrap getInitialLocale() in try-catch in ALL preload scripts.

    The eipc origin validator only accepts https://claude.ai origins. During
    preload execution the frame URL is still file:// (initial HTML), so the
    getInitialLocale() sendSync call throws, killing the preload before
    window.process is exposed. We default to empty messages + 'en-US'.

    Affected preloads: mainWindow.js, quickWindow.js, aboutWindow.js,
    findInPage.js, mainView.js — all share the same eipc locale pattern.
    """
    import re as _re
    import glob as _glob

    build_dir = os.path.join(asar_dir, '.vite', 'build')
    if not os.path.isdir(build_dir):
        print('  [warn] .vite/build/ not found — skipping locale patches')
        return

    patched = 0
    for preload_path in sorted(_glob.glob(os.path.join(build_dir, '*.js'))):
        basename = os.path.basename(preload_path)
        with open(preload_path, 'r', encoding='utf-8') as f:
            content = f.read()

        m = _re.search(
            r'const\{messages:(\w+),locale:(\w+)\}=(\w+)\.getInitialLocale\(\)',
            content
        )
        if not m:
            continue

        v1, v2, iface = m.group(1), m.group(2), m.group(3)
        old = m.group(0)
        new = (f'let {v1}=[],{v2}="en-US";'
               f'try{{const _r={iface}.getInitialLocale();{v1}=_r.messages;{v2}=_r.locale;}}catch(_e){{}}')
        content = content.replace(old, new, 1)

        with open(preload_path, 'w', encoding='utf-8') as f:
            f.write(content)

        patched += 1
        print(f'  [ok] {basename}: getInitialLocale() wrapped in try-catch')

    if patched == 0:
        print('  [warn] No preloads found with getInitialLocale() pattern')
    else:
        print(f'  [ok] Patched {patched} preload(s)')
