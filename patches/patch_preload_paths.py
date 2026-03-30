"""
Patch preload script paths to load from the real filesystem instead of the asar VFS.

Electron 35+ sandboxed renderers cannot read preload scripts from inside the asar VFS.
All preloads are extracted to the real filesystem at .vite/build/ alongside the asar.

The pattern:
    preload:PATH.join(ELECTRON.app.getAppPath(), ".vite/build/X.js")

resolves to:
    /path/to/app.asar/.vite/build/X.js   ← inside asar, fails in sandbox

We change it to:
    preload:PATH.join(PATH.dirname(ELECTRON.app.getAppPath()), ".vite/build/X.js")

which resolves to:
    /path/to/.vite/build/X.js            ← real filesystem, always works
"""

import re


PATTERN = re.compile(
    r'(preload:)(\w+)\.join\((\w+)\.app\.getAppPath\(\),(\"\.vite/build/\w+\.js\")\)'
)


def apply(content):
    count = 0

    def replacer(m):
        nonlocal count
        prefix, path_var, electron_var, preload_rel = m.groups()
        count += 1
        return (
            f'{prefix}{path_var}.join({path_var}.dirname({electron_var}.app.getAppPath()),'
            f'{preload_rel})'
        )

    new_content = PATTERN.sub(replacer, content)

    if count > 0:
        print(f'  [ok] Patched {count} preload path(s): getAppPath() → dirname(getAppPath())')
    else:
        print('  [warn] patch_preload_paths: no preload path patterns found')

    return new_content, count > 0
