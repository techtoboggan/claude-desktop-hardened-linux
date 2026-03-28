"""Patch isSupportedPlatform constant to include Linux."""

import re


def apply(content):
    """
    Patch the Xze (isSupportedPlatform) constant to include Linux.

    The app defines:
      const Hr = process.platform === "darwin"
      const Pn = process.platform === "win32"
      const Xze = Hr || Pn

    We add || process.platform==="linux" so Linux is treated as supported.
    Hr and Pn are NOT patched — they gate platform-specific behavior.
    """
    pattern = r'(const\s+\w+=\w+\|\|\w+;)(function\s+\w+\(\)\{try\{return\s+process\.execPath)'
    match = re.search(pattern, content)
    if match:
        old_const = match.group(1)
        const_match = re.match(r'const\s+(\w+)=(\w+)\|\|(\w+);', old_const)
        if const_match:
            var_name = const_match.group(1)
            mac_var = const_match.group(2)
            win_var = const_match.group(3)
            new_const = f'const {var_name}={mac_var}||{win_var}||process.platform==="linux";'
            content = content.replace(old_const, new_const, 1)
            print(f'  [ok] Patched {var_name} to include Linux')
            return content, True

    old = 'Xze=Hr||Pn;'
    if old in content:
        content = content.replace(old, 'Xze=Hr||Pn||process.platform==="linux";', 1)
        print('  [ok] Patched Xze to include Linux (direct match)')
        return content, True

    pattern2 = r'(=process\.platform==="darwin",\w+=process\.platform==="win32",)(\w+)=(\w+)\|\|(\w+)'
    match2 = re.search(pattern2, content)
    if match2:
        var_name = match2.group(2)
        mac_var = match2.group(3)
        win_var = match2.group(4)
        old_text = match2.group(0)
        new_text = f'{match2.group(1)}{var_name}={mac_var}||{win_var}||process.platform==="linux"'
        content = content.replace(old_text, new_text, 1)
        print(f'  [ok] Patched {var_name} to include Linux (pattern2)')
        return content, True

    print('  [warn] Could not find platform constant to patch')
    return content, False
