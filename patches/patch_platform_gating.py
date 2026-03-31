"""Patch platform gating functions to accept Linux."""

import re
from .base import find_brace_block


def apply(content):
    """
    Replace ALL platform gating functions with Linux-aware versions.

    Multiple functions check process.platform against "darwin"/"win32"
    and return unsupported/unavailable for anything else. We patch all
    pattern variants.
    """
    total_patched = 0

    # Pattern 1: functions checking both darwin AND win32
    #   function X(){const t=process.platform;if(t!=="darwin"&&t!=="win32")return{status:"unsupported"...
    # Note: [\w$] because JS minifiers produce identifiers like $un
    pattern1 = r'function\s+([\w$]+)\s*\(\)\s*\{const\s+[\w$]=process\.platform;if\([\w$]!=="darwin"&&[\w$]!=="win32"\)return\{status:"unsupported"'

    for match in reversed(list(re.finditer(pattern1, content))):
        func_name = match.group(1)
        func_start = match.start()
        func_end = find_brace_block(content, func_start)
        if func_end is None:
            print(f'  [warn] Could not find end of {func_name}(), skipping')
            continue
        print(f'  [found] Platform gating (darwin+win32): {func_name}()')
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
        total_patched += 1

    # Pattern 2: functions returning "unavailable" for non-darwin
    #   function X(){return process.platform!=="darwin"?{status:"unavailable"}:{status:"supported"}}
    pattern2 = r'function\s+(\w+)\s*\(\)\s*\{return process\.platform!=="darwin"\?\{status:"unavailable"\}:\{status:"supported"\}\}'

    for match in reversed(list(re.finditer(pattern2, content))):
        func_name = match.group(1)
        print(f'  [found] Platform gating (darwin-only unavailable): {func_name}()')
        replacement = (
            f'function {func_name}()'
            '{return(process.platform==="darwin"||process.platform==="linux")'
            '?{status:"supported"}:{status:"unavailable"}}'
        )
        content = content[:match.start()] + replacement + content[match.end():]
        total_patched += 1

    # Pattern 3: detectedProjects macOS-only bail-out
    #   if(process.platform!=="darwin")return ...,[]; → also allow linux
    pattern3 = r'if\(process\.platform!=="darwin"\)return [^,]+,\[\]'

    for match in reversed(list(re.finditer(pattern3, content))):
        original = match.group(0)
        replacement = original.replace(
            'process.platform!=="darwin"',
            'process.platform!=="darwin"&&process.platform!=="linux"'
        )
        content = content[:match.start()] + replacement + content[match.end():]
        total_patched += 1
        print(f'  [found] detectedProjects macOS-only gate — added Linux')

    if total_patched == 0:
        print('  [FAIL] Could not find any platform gating functions')
        return content, False

    print(f'  [ok] Patched {total_patched} platform gate(s) total')
    return content, True
