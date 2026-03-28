"""Add Linux entries to the VM image manifest."""

import re


def apply(content):
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
            return content, True
        else:
            print('  [FAIL] Could not find VM manifest at all')
            return content, False

    insert_text = match.group(0)
    replacement = 'files:{' + linux_entry + ',' + insert_text[len('files:{'):]
    content = content.replace(insert_text, replacement, 1)
    print('  [ok] Added Linux entry to VM manifest')
    return content, True
