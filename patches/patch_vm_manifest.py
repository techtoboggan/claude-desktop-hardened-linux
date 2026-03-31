"""Add Linux entries to the VM image manifest."""

import os
import re


def apply(content, asar_dir=None):
    """
    Add linux:{x64,arm64} to qn.files so the VM image check passes.

    On Linux we run Claude Code directly (no VM), but the manifest
    check must pass for the UI to enable Cowork.
    """
    linux_entry = (
        'linux:{x64:[{name:"native",checksum:"0",progressStart:0,progressEnd:100}],'
        'arm64:[{name:"native",checksum:"0",progressStart:0,progressEnd:100}]}'
    )

    pattern = r'(files:\{darwin:\{[^}]+\}[^}]*\})'
    match = re.search(pattern, content)

    if not match:
        pattern = r'(files:\{darwin:\{arm64:\[[^\]]*\],x64:\[[^\]]*\]\})'
        match = re.search(pattern, content)

    if not match:
        sha_pattern = r'(sha:"[a-f0-9]+",files:\{)'
        sha_match = re.search(sha_pattern, content)
        if sha_match:
            insert_point = sha_match.end()
            content = content[:insert_point] + linux_entry + ',' + content[insert_point:]
            print('  [ok] Injected Linux VM manifest entry (via sha fallback)')
            _write_vm_sha(content, asar_dir)
            return content, True
        else:
            print('  [FAIL] Could not find VM manifest at all')
            return content, False

    insert_text = match.group(0)
    replacement = 'files:{' + linux_entry + ',' + insert_text[len('files:{'):]
    content = content.replace(insert_text, replacement, 1)
    print('  [ok] Added Linux entry to VM manifest')
    _write_vm_sha(content, asar_dir)
    return content, True


def _write_vm_sha(content, asar_dir):
    """Extract the VM manifest SHA and write it to .vm-sha in the asar dir."""
    if not asar_dir:
        return
    sha_match = re.search(r'sha:"([a-f0-9]{40,})"', content)
    if not sha_match:
        print('  [warn] Could not extract VM manifest SHA')
        return
    sha = sha_match.group(1)
    sha_path = os.path.join(asar_dir, '.vm-sha')
    with open(sha_path, 'w') as f:
        f.write(sha)
    print(f'  [ok] Wrote VM manifest SHA to .vm-sha: {sha}')
