"""Patch getHostPlatform() to support Linux."""

import re


def apply(content):
    """
    Add Linux case to SCt.getHostPlatform().

    The Claude Code binary manager maps process.platform/arch to a
    platform string. It only handles "darwin" and "win32", throwing on Linux.
    """
    pattern = (
        r'getHostPlatform\(\)\{const (\w)=process\.arch;'
        r'if\(process\.platform==="darwin"\)return \1==="arm64"\?"darwin-arm64":"darwin-x64";'
        r'if\(process\.platform==="win32"\)return \1==="arm64"\?"win32-arm64":"win32-x64";'
        r'throw new Error\(`Unsupported platform: \$\{process\.platform\}-\$\{\1\}`\)\}'
    )

    match = re.search(pattern, content)
    if match:
        arch_var = match.group(1)
        replacement = (
            f'getHostPlatform(){{const {arch_var}=process.arch;'
            f'if(process.platform==="darwin")return {arch_var}==="arm64"?"darwin-arm64":"darwin-x64";'
            f'if(process.platform==="win32")return {arch_var}==="arm64"?"win32-arm64":"win32-x64";'
            f'if(process.platform==="linux")return {arch_var}==="arm64"?"linux-arm64":"linux-x64";'
            f'throw new Error(`Unsupported platform: ${{process.platform}}-${{{arch_var}}}`)}}'
        )
        content = content[:match.start()] + replacement + content[match.end():]
        print('  [ok] Patched getHostPlatform() to support Linux')
        return content, True

    fallback = r'throw new Error\(`Unsupported platform: \$\{process\.platform\}-\$\{(\w)\}`\)\}'
    match2 = re.search(fallback, content)
    if match2:
        arch_var = match2.group(1)
        insert = f'if(process.platform==="linux")return {arch_var}==="arm64"?"linux-arm64":"linux-x64";'
        content = content[:match2.start()] + insert + content[match2.start():]
        print('  [ok] Patched getHostPlatform() with Linux fallback (inserted before throw)')
        return content, True

    print('  [FAIL] Could not find getHostPlatform() to patch')
    return content, False
