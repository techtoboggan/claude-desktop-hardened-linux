"""
Patch preload script paths and process.resourcesPath usages.

1. Preload paths: Electron 35+ sandboxed renderers cannot read preload scripts
   from inside the asar VFS. All preloads are extracted to the real filesystem.
   Change: getAppPath()      → dirname(getAppPath())

2. process.resourcesPath: When running with a system Electron binary (not a
   bundled app), process.resourcesPath points to Electron's own resources
   directory rather than our app's directory. Fix by replacing usages that
   construct paths relative to resourcesPath/"app.asar" with paths derived
   from app.getAppPath() (which always resolves correctly).

   Affected: shell-path-worker lookup, cowork-plugin-shim lookup.
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

    # -------------------------------------------------------------------------
    # Fix process.resourcesPath for shell-path-worker
    #
    # Original: function Rtn(){return ve.join(process.resourcesPath,"app.asar",...)}
    # Patched:  function Rtn(){return ve.join(ve.dirname(Se.app.getAppPath()),"app.asar",...)}
    #
    # This ensures the path resolves against the actual installed asar location
    # rather than the system Electron binary's resources directory.
    # -------------------------------------------------------------------------
    pat_shellworker = re.compile(
        r'(function [\w$]+\(\)\{return )([\w$]+)\.join\(process\.resourcesPath,'
        r'"app\.asar","\.vite","build","shell-path-worker","shellPathWorker\.js"\)\}'
    )
    def replace_shellworker(m):
        nonlocal count
        prefix, path_var = m.group(1), m.group(2)
        # Find the electron var (Se/xe) — look for it in surrounding context
        # We use app.getAppPath() which always resolves correctly
        # Se is the electron require — find it by looking at what's used elsewhere
        # Safe approach: use a require() call directly
        count += 1
        return (
            f'{prefix}{path_var}.join('
            f'{path_var}.dirname(require("electron").app.getAppPath()),'
            f'"app.asar",".vite","build","shell-path-worker","shellPathWorker.js")}}'
        )
    new_content, sub_count = pat_shellworker.subn(replace_shellworker, new_content)
    if sub_count:
        print(f'  [ok] Patched shell-path-worker path: process.resourcesPath → app.getAppPath() dirname')

    # -------------------------------------------------------------------------
    # Fix isPackaged/resourcesPath for cowork-plugin-shim
    #
    # Original: Se.app.isPackaged?process.resourcesPath:ve.join(__dirname,"..","..","resources")
    # Patched:  ve.dirname(Se.app.getAppPath())
    #
    # On Linux with system Electron, isPackaged=false so it falls into the dev
    # path (__dirname/../../resources) which also resolves incorrectly. Use
    # getAppPath() dirname instead — always the directory containing app.asar.
    # -------------------------------------------------------------------------
    pat_shim = re.compile(
        r'([\w$]+\.app\.isPackaged\?process\.resourcesPath'
        r':[\w$]+\.join\(__dirname,"\.\.","\.\.","resources"\))'
        r'(,[\w$]+=[\w$]+\.join\([\w$]+,"shim-lib"\))'
    )
    def replace_shim(m):
        nonlocal count
        rest = m.group(2)
        # Grab the electron and path vars from the shell-path-worker patch context
        # Safe fallback: use require() directly
        count += 1
        return f'require("path").dirname(require("electron").app.getAppPath()){rest}'
    new_content, sub_count2 = pat_shim.subn(replace_shim, new_content)
    if sub_count2:
        print(f'  [ok] Patched cowork-plugin-shim path: isPackaged branch → app.getAppPath() dirname')

    return new_content, count > 0
