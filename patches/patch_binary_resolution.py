"""Patch getLocalBinaryPath() to find system-installed Claude Code on Linux.

Prefer user-local installs (~/.local/bin) over system packages (/usr/bin)
because user-local installs are kept current by `claude update` and carry
newer built-in tools (e.g. SendUserMessage for Dispatch).
"""

import re


def apply(content):
    pattern = r'async getLocalBinaryPath\(\)\{return this\.localBinaryInitPromise&&await this\.localBinaryInitPromise,this\.localBinaryPath\}'
    match = re.search(pattern, content)
    if match:
        replacement = (
            'async getLocalBinaryPath(){'
            'if(process.platform==="linux"){'
            'const fs=require("fs"),os=require("os"),'
            'paths=['
            'os.homedir()+"/.local/bin/claude",'
            'os.homedir()+"/.npm-global/bin/claude",'
            '"/usr/local/bin/claude","/usr/bin/claude"];'
            'for(const p of paths){try{await fs.promises.access(p);return p}catch{}}'
            '}'
            'return this.localBinaryInitPromise&&await this.localBinaryInitPromise,this.localBinaryPath}'
        )
        content = content[:match.start()] + replacement + content[match.end():]
        print('  [ok] Patched getLocalBinaryPath() to find system Claude on Linux')
        return content, True

    print('  [warn] Could not find getLocalBinaryPath() to patch')
    return content, False
