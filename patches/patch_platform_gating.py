"""Patch platform gating functions to accept Linux."""

import re
from .base import find_brace_block


def apply(content):
    """
    Replace ALL platform gating functions with Linux-aware versions.

    Multiple functions check process.platform against "darwin"/"win32"
    and return unsupported for anything else. We patch all of them.
    """
    pattern = r'function\s+(\w+)\s*\(\)\s*\{const\s+\w=process\.platform;if\(\w!=="darwin"&&\w!=="win32"\)return\{status:"unsupported"'

    matches = list(re.finditer(pattern, content))

    if not matches:
        print('  [FAIL] Could not find any platform gating functions')
        return content, False

    print(f'  [found] {len(matches)} platform gating function(s)')

    for match in reversed(matches):
        func_name = match.group(1)
        func_start = match.start()
        func_end = find_brace_block(content, func_start)

        if func_end is None:
            print(f'  [warn] Could not find end of {func_name}(), skipping')
            continue

        original_func = content[func_start:func_end]
        print(f'  [found] Platform gating function: {func_name}() ({len(original_func)} bytes)')

        replacement = (
            f'function {func_name}()'
            '{const t=process.platform;'
            'if(t==="linux")return{status:"supported"};'
            'if(t!=="darwin"&&t!=="win32")return{status:"unsupported",'
            'reason:"Cowork is not supported on this platform",'
            'unsupportedCode:"unsupported_platform"};'
            'const e=process.arch;'
            'if(e!=="x64"&&e!=="arm64")return{status:"unsupported",'
            'reason:"Unsupported architecture",'
            'unsupportedCode:"unsupported_architecture"};'
            'return{status:"supported"}}'
        )

        content = content[:func_start] + replacement + content[func_end:]
        print(f'  [ok] Replaced {func_name}() with Linux-aware version')

    return content, True
