"""Spoof platform headers for Anthropic API requests."""

import re


def apply(content):
    """
    Spoof OS platform headers so the server enables Cowork features.

    The API may check Anthropic-Client-OS-Platform to gate feature availability.
    """
    patched = re.sub(
        r'("Anthropic-Client-OS-Platform"\s*:\s*)["\'][^"\']*["\']',
        r'\1"darwin"',
        content
    )
    patched = re.sub(
        r'("Anthropic-Client-OS-Version"\s*:\s*)["\'][^"\']*["\']',
        r'\1"14.0"',
        patched
    )

    if patched != content:
        print('  [ok] Spoofed API platform headers')
    else:
        print('  [skip] No static platform headers found to spoof')

    return patched, True
