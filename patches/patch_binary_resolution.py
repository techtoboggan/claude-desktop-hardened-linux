"""Patch getLocalBinaryPath() to find system-installed Claude Code on Linux."""

import re


def apply(content):
    """
    On Linux, Claude Code is installed system-wide. Patch getLocalBinaryPath()
    to check standard paths before falling through to the managed-download flow.
    """
    pattern = r'async getLocalBinaryPath\(\)\{return this\.localBinaryInitPromise&&await this\.localBinaryInitPromise,this\.localBinaryPath\}'
    match = re.search(pattern, content)
    if match:
        replacement = (
            'async getLocalBinaryPath(){'
            'if(process.platform==="linux"){'
            'const fs=require("fs"),os=require("os"),'
            'paths=["/usr/bin/claude","/usr/local/bin/claude",'
            'os.homedir()+"/.local/bin/claude",'
            'os.homedir()+"/.npm-global/bin/claude"];'
            'for(const p of paths){try{await fs.promises.access(p);return p}catch{}}'
            '}'
            'return this.localBinaryInitPromise&&await this.localBinaryInitPromise,this.localBinaryPath}'
        )
        content = content[:match.start()] + replacement + content[match.end():]
        print('  [ok] Patched getLocalBinaryPath() to find system Claude on Linux')
        return content, True

    print('  [warn] Could not find getLocalBinaryPath() to patch')
    return content, False
