#!/usr/bin/env python3
"""
Enable Cowork (Local Agent Mode) in Claude Desktop for Linux.

Applies modular patches from the patches/ directory to the extracted
app.asar contents. See patches/ for individual patch documentation.

Usage:
    python3 enable-cowork.py <path-to-app.asar.contents>
"""

import os
import sys

# Allow running from any directory
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from patches.runner import run

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(f'Usage: {sys.argv[0]} <path-to-app.asar.contents>')
        sys.exit(1)

    asar_dir = sys.argv[1]
    if not os.path.isdir(asar_dir):
        print(f'Error: {asar_dir} is not a directory')
        sys.exit(1)

    sys.exit(run(asar_dir))
