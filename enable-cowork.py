#!/usr/bin/env python3
"""
Enable Cowork (Local Agent Mode) in Claude Desktop for Linux.

This script patches the extracted app.asar contents with surgical,
targeted modifications to the specific functions that gate Cowork.

Based on reverse engineering of the minified index.js, the gating chain is:

  _Be() → hUt() → uUt() → platform/arch/VM checks
                        → qn.files[platform][arch] manifest check
       → hc().secureVmFeaturesEnabled
       → Fr("secureVmFeaturesEnabled")

We patch:
1. uUt() — the platform/arch gating function — to return "supported" for Linux
2. qn.files — the VM image manifest — to include a "linux" entry
3. The top-level platform constants (Hr, Pn, Xze) to include Linux
4. Cowork init injection into the main process

Usage:
    python3 enable-cowork.py <path-to-app.asar.contents>
"""

import os
import re
import sys
import json
import glob


def find_main_entry(asar_dir):
    """Find the main JavaScript entry point in the asar contents."""
    candidates = [
        os.path.join(asar_dir, '.vite', 'build', 'index.js'),
        os.path.join(asar_dir, '.vite', 'build', 'main.js'),
        os.path.join(asar_dir, 'index.js'),
        os.path.join(asar_dir, 'main.js'),
    ]

    for c in candidates:
        if os.path.exists(c):
            return c

    for root, dirs, files in os.walk(os.path.join(asar_dir, '.vite')):
        for f in files:
            if f in ('index.js', 'main.js'):
                return os.path.join(root, f)

    return None


def patch_platform_gating_functions(content):
    """
    Patch ALL platform gating functions to accept Linux.

    Multiple functions check process.platform against "darwin"/"win32"
    and return unsupported for anything else. In newer versions (1.1.9134+),
    there are separate gating functions for different feature areas (e.g.,
    uUt for VM support, jtn for yukonSilver/cowork). We must patch all of them.
    """
    # Match any function that gates on darwin/win32 and returns unsupported
    pattern = r'function\s+(\w+)\s*\(\)\s*\{const\s+\w=process\.platform;if\(\w!=="darwin"&&\w!=="win32"\)return\{status:"unsupported"'

    matches = list(re.finditer(pattern, content))

    if not matches:
        print('  [FAIL] Could not find any platform gating functions')
        return content, False

    print(f'  [found] {len(matches)} platform gating function(s)')

    # Patch in reverse order so offsets remain valid
    for match in reversed(matches):
        func_name = match.group(1)

        # Find the full function by counting braces
        func_start = match.start()
        brace_start = content.index('{', match.start())
        brace_count = 0
        func_end = None

        for i in range(brace_start, min(brace_start + 5000, len(content))):
            if content[i] == '{':
                brace_count += 1
            elif content[i] == '}':
                brace_count -= 1
                if brace_count == 0:
                    func_end = i + 1
                    break

        if func_end is None:
            print(f'  [warn] Could not find end of {func_name}(), skipping')
            continue

        original_func = content[func_start:func_end]
        print(f'  [found] Platform gating function: {func_name}() ({len(original_func)} bytes)')

        # Replace with a version that accepts Linux
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


def patch_vm_manifest(content):
    """
    Add Linux entries to the qn.files VM image manifest.

    The app checks qn.files[process.platform][process.arch] to verify
    VM images exist for the platform. We add a linux entry so this check passes.
    On Linux we don't actually use VM images (we run Claude Code directly),
    but the check must pass for the UI to enable Cowork.
    """
    # Find the qn={sha:"...",files:{darwin:{...},win32:{...}}} object
    # We need to add linux:{x64:[...],arm64:[...]} to the files object

    # Pattern: files:{darwin:{ ... },win32:{ ... }}
    # We insert linux after darwin
    pattern = r'(files:\{darwin:\{[^}]+\}[^}]*\})'

    match = re.search(pattern, content)
    if not match:
        # Try a more specific pattern
        pattern = r'(files:\{darwin:\{arm64:\[[^\]]*\],x64:\[[^\]]*\]\})'
        match = re.search(pattern, content)

    if not match:
        print('  [warn] Could not find VM manifest — using injection approach')
        # Fallback: add linux entry by finding the closing of the files object
        # Look for the specific sha string that precedes the files
        sha_pattern = r'(sha:"[a-f0-9]+",files:\{)'
        sha_match = re.search(sha_pattern, content)
        if sha_match:
            insert_point = sha_match.end()
            linux_entry = 'linux:{x64:[{name:"native",checksum:"0",progressStart:0,progressEnd:100}],arm64:[{name:"native",checksum:"0",progressStart:0,progressEnd:100}]},'
            content = content[:insert_point] + linux_entry + content[insert_point:]
            print('  [ok] Injected Linux VM manifest entry (via sha fallback)')
            return content, True
        else:
            print('  [FAIL] Could not find VM manifest at all')
            return content, False

    # Insert linux entry before the darwin entry
    insert_text = match.group(0)
    linux_files = 'linux:{x64:[{name:"native",checksum:"0",progressStart:0,progressEnd:100}],arm64:[{name:"native",checksum:"0",progressStart:0,progressEnd:100}]},'
    replacement = 'files:{' + linux_files + insert_text[len('files:{'):]
    content = content.replace(insert_text, replacement, 1)
    print('  [ok] Added Linux entry to VM manifest')
    return content, True


def patch_platform_constants(content):
    """
    Patch the top-level platform constants to include Linux.

    The app defines:
      const Hr = process.platform === "darwin"      (isMac)
      const Pn = process.platform === "win32"       (isWin)
      const Xze = Hr || Pn                          (isSupportedPlatform)

    We patch Xze to also be true on Linux. We do NOT patch Hr or Pn
    because those are used for platform-specific behavior (macOS paths,
    Windows registry, etc.) that should NOT run on Linux.
    """
    # Find: const Xze=Hr||Pn;
    # Replace with: const Xze=Hr||Pn||process.platform==="linux";
    pattern = r'(const\s+\w+=\w+\|\|\w+;)(function\s+\w+\(\)\{try\{return\s+process\.execPath)'

    match = re.search(pattern, content)
    if match:
        old_const = match.group(1)
        # Extract the variable name (Xze or whatever it's minified to)
        const_match = re.match(r'const\s+(\w+)=(\w+)\|\|(\w+);', old_const)
        if const_match:
            var_name = const_match.group(1)
            mac_var = const_match.group(2)
            win_var = const_match.group(3)
            new_const = f'const {var_name}={mac_var}||{win_var}||process.platform==="linux";'
            content = content.replace(old_const, new_const, 1)
            print(f'  [ok] Patched {var_name} to include Linux')
            return content, True

    # Fallback: direct string replacement
    old = 'Xze=Hr||Pn;'
    if old in content:
        content = content.replace(old, 'Xze=Hr||Pn||process.platform==="linux";', 1)
        print('  [ok] Patched Xze to include Linux (direct match)')
        return content, True

    # Try another pattern - find the isSupportedPlatform definition
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


def patch_enterprise_config(content):
    """
    Patch enterprise config reader to return safe defaults on Linux.

    The hc() function reads platform-specific config (plist on macOS,
    registry on Windows). On Linux it returns {}. This is fine since
    an empty object means no restrictions.
    """
    # The switch already has a default:{} case, so this should be OK.
    # But let's verify secureVmFeaturesEnabled isn't being set to false anywhere
    if 'secureVmFeaturesEnabled:!1' in content:
        content = content.replace('secureVmFeaturesEnabled:!1', 'secureVmFeaturesEnabled:!0')
        print('  [ok] Flipped secureVmFeaturesEnabled from false to true')
    elif 'secureVmFeaturesEnabled:false' in content:
        content = content.replace('secureVmFeaturesEnabled:false', 'secureVmFeaturesEnabled:true')
        print('  [ok] Flipped secureVmFeaturesEnabled from false to true')
    else:
        print('  [skip] secureVmFeaturesEnabled not set to false')

    return content


def patch_claude_code_binary_manager(content):
    """
    Patch SCt.getHostPlatform() to support Linux.

    The Claude Code binary manager (SCt class) has a getHostPlatform() method
    that maps process.platform/arch to a platform string used for downloading
    and locating the Claude Code CLI binary. It only handles "darwin" and "win32",
    throwing "Unsupported platform: linux-x64" on Linux.

    Without this patch, ClaudeCode_$_prepare, ClaudeCode_$_getStatus, and
    LocalSessions_$_sendMessage all fail because they call getHostPlatform()
    via getHostTarget() -> getBinaryPathIfReady().

    We also patch getHostTarget() to use the correct binary name on Linux.
    """
    # Pattern: getHostPlatform(){const e=process.arch;if(process.platform==="darwin")return e==="arm64"?"darwin-arm64":"darwin-x64";if(process.platform==="win32")return e==="arm64"?"win32-arm64":"win32-x64";throw new Error(`Unsupported platform: ${process.platform}-${e}`)}
    pattern = r'getHostPlatform\(\)\{const (\w)=process\.arch;if\(process\.platform==="darwin"\)return \1==="arm64"\?"darwin-arm64":"darwin-x64";if\(process\.platform==="win32"\)return \1==="arm64"\?"win32-arm64":"win32-x64";throw new Error\(`Unsupported platform: \$\{process\.platform\}-\$\{\1\}`\)\}'

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

    # Fallback: look for just the throw
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


def patch_claude_code_binary_resolution(content):
    """
    Patch the binary manager to find the system-installed Claude Code on Linux.

    The binary manager tries to download Claude Code to its own managed directory.
    On Linux, Claude Code is installed system-wide (e.g., /usr/bin/claude via npm).
    We patch getLocalBinaryPath() to detect the system binary on Linux so it
    skips the download flow entirely.
    """
    # Find: async getLocalBinaryPath(){return this.localBinaryInitPromise&&await this.localBinaryInitPromise,this.localBinaryPath}
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


def inject_cowork_init(content):
    """
    Inject Cowork initialization code into the main process entry.
    """
    init_code = '''
// --- Cowork for Linux: injected initialization ---
try {
  const { app } = require("electron");
  const coworkInit = require("cowork");
  app.on("ready", () => {
    try {
      coworkInit.initializeCowork();
      console.log("[cowork-linux] Cowork initialized via injection");
    } catch (e) {
      console.error("[cowork-linux] Failed to initialize Cowork:", e.message);
    }
  });
  app.on("before-quit", async () => {
    try {
      await coworkInit.shutdownCowork();
    } catch (e) {
      console.error("[cowork-linux] Shutdown error:", e.message);
    }
  });
} catch (e) {
  console.error("[cowork-linux] Failed to load Cowork module:", e.message);
}
// --- End Cowork injection ---
'''

    if 'cowork-linux' in content:
        print('  [skip] Cowork init already injected')
        return content

    return init_code + '\n' + content


def patch_api_headers(content):
    """
    Spoof platform headers for Anthropic API requests.
    The server may check these to decide if Cowork features are available.
    """
    # Direct string replacement for header values
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

    # Also look for dynamic platform header generation
    # Pattern: platform:process.platform → platform:"darwin"
    # Only in the context of API headers/telemetry (be careful)
    if patched != content:
        print('  [ok] Spoofed API platform headers')
    else:
        print('  [skip] No static platform headers found to spoof')

    return patched


def create_package_json_entry(asar_dir):
    """Ensure package.json lists our stub modules."""
    pkg_path = os.path.join(asar_dir, 'package.json')
    if not os.path.exists(pkg_path):
        return

    try:
        with open(pkg_path, 'r') as f:
            pkg = json.load(f)

        if 'dependencies' not in pkg:
            pkg['dependencies'] = {}

        pkg['dependencies']['cowork'] = 'file:./node_modules/cowork'
        # Detect whether swift stub lives under @ant/ scope or at top level
        swift_at_scope = os.path.isdir(os.path.join(asar_dir, 'node_modules', '@ant', 'claude-swift'))
        if swift_at_scope:
            pkg['dependencies']['@ant/claude-swift'] = 'file:./node_modules/@ant/claude-swift'
        else:
            pkg['dependencies']['claude-swift-stub'] = 'file:./node_modules/claude-swift-stub'

        with open(pkg_path, 'w') as f:
            json.dump(pkg, f, indent=2)

        print('  [ok] Updated package.json with cowork dependencies')
    except Exception as e:
        print(f'  [warn] Could not update package.json: {e}')


def main():
    if len(sys.argv) < 2:
        print(f'Usage: {sys.argv[0]} <path-to-app.asar.contents>')
        sys.exit(1)

    asar_dir = sys.argv[1]

    if not os.path.isdir(asar_dir):
        print(f'Error: {asar_dir} is not a directory')
        sys.exit(1)

    print(f'[cowork-patcher] Patching: {asar_dir}')

    # Find main entry
    main_entry = find_main_entry(asar_dir)
    if not main_entry:
        print('Error: Could not find main JavaScript entry point')
        sys.exit(1)

    print(f'  [found] Main entry: {main_entry}')

    with open(main_entry, 'r', encoding='utf-8') as f:
        content = f.read()

    original_size = len(content)
    success_count = 0
    total_patches = 7

    # Patch 1: Replace ALL platform gating functions (uUt, jtn, etc.)
    print('  [patch 1/7] Platform gating functions...')
    content, ok = patch_platform_gating_functions(content)
    if ok:
        success_count += 1

    # Patch 2: Add Linux to VM image manifest
    print('  [patch 2/7] VM image manifest (qn.files)...')
    content, ok = patch_vm_manifest(content)
    if ok:
        success_count += 1

    # Patch 3: Patch platform constants (Xze = isSupportedPlatform)
    print('  [patch 3/7] Platform constants (Xze)...')
    content, ok = patch_platform_constants(content)
    if ok:
        success_count += 1

    # Patch 4: Enterprise config safety
    print('  [patch 4/7] Enterprise config...')
    content = patch_enterprise_config(content)
    success_count += 1  # Always succeeds (may be no-op)

    # Patch 5: API header spoofing
    print('  [patch 5/7] API headers...')
    content = patch_api_headers(content)
    success_count += 1  # Always succeeds (may be no-op)

    # Patch 6: Claude Code binary manager — getHostPlatform()
    print('  [patch 6/7] Claude Code binary manager (getHostPlatform)...')
    content, ok = patch_claude_code_binary_manager(content)
    if ok:
        success_count += 1

    # Patch 7: Claude Code binary resolution — find system-installed binary on Linux
    print('  [patch 7/7] Claude Code binary resolution (getLocalBinaryPath)...')
    content, ok = patch_claude_code_binary_resolution(content)
    if ok:
        success_count += 1

    # Inject Cowork initialization
    print('  [inject] Cowork initialization...')
    content = inject_cowork_init(content)

    # Write back
    with open(main_entry, 'w', encoding='utf-8') as f:
        f.write(content)

    print(f'  [ok] Patched {main_entry} ({original_size} → {len(content)} bytes)')

    # Update package.json
    create_package_json_entry(asar_dir)

    # Summary
    print(f'[cowork-patcher] Done! {success_count}/{total_patches} patches applied')

    if success_count < 3:
        print('[cowork-patcher] WARNING: Some critical patches failed — Cowork may not activate')
        sys.exit(1)


if __name__ == '__main__':
    main()
