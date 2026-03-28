"""
Tests for the modular patch system.

Run: python3 -m pytest tests/test_patches.py -v
  or: python3 -m unittest tests/test_patches.py -v
"""

import os
import sys
import unittest

# Add repo root to path
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from patches import (
    patch_platform_gating,
    patch_vm_manifest,
    patch_platform_constants,
    patch_enterprise_config,
    patch_api_headers,
    patch_binary_manager,
    patch_binary_resolution,
    inject_cowork_init,
)
from patches.base import find_brace_block


class TestFindBraceBlock(unittest.TestCase):
    def test_simple_block(self):
        content = 'function foo(){return 1;}'
        end = find_brace_block(content, 0)
        self.assertEqual(end, len(content))

    def test_nested_blocks(self):
        content = 'function foo(){if(true){return 1;}}'
        end = find_brace_block(content, 0)
        self.assertEqual(end, len(content))

    def test_returns_none_for_unclosed(self):
        content = 'function foo(){'
        end = find_brace_block(content, 0)
        self.assertIsNone(end)


class TestPlatformGating(unittest.TestCase):
    SAMPLE = (
        'function uUt(){const t=process.platform;'
        'if(t!=="darwin"&&t!=="win32")return{status:"unsupported",'
        'reason:"Cowork is not supported on this platform",'
        'unsupportedCode:"unsupported_platform"};'
        'const e=process.arch;'
        'if(e!=="x64"&&e!=="arm64")return{status:"unsupported"};'
        'return{status:"supported"}}'
    )

    def test_patches_platform_gating(self):
        result, ok = patch_platform_gating.apply(self.SAMPLE)
        self.assertTrue(ok)
        self.assertIn('linux', result)
        self.assertIn('status:"supported"', result)

    def test_returns_false_on_no_match(self):
        result, ok = patch_platform_gating.apply('const x = 1;')
        self.assertFalse(ok)


class TestVmManifest(unittest.TestCase):
    SAMPLE = 'const qn={sha:"abc123",files:{darwin:{arm64:[{name:"vm"}],x64:[{name:"vm"}]},win32:{x64:[{name:"vm"}]}}};'

    def test_adds_linux_entry(self):
        result, ok = patch_vm_manifest.apply(self.SAMPLE)
        self.assertTrue(ok)
        self.assertIn('linux:', result)
        self.assertIn('native', result)

    def test_sha_fallback(self):
        sample = 'sha:"deadbeef",files:{darwin:{x64:[]}}'
        result, ok = patch_vm_manifest.apply(sample)
        self.assertTrue(ok)
        self.assertIn('linux:', result)


class TestPlatformConstants(unittest.TestCase):
    def test_patches_direct_match(self):
        sample = 'const Hr=process.platform==="darwin",Pn=process.platform==="win32",Xze=Hr||Pn;function foo(){try{return process.execPath'
        result, ok = patch_platform_constants.apply(sample)
        self.assertTrue(ok)
        self.assertIn('process.platform==="linux"', result)

    def test_returns_false_on_no_match(self):
        result, ok = patch_platform_constants.apply('const x = 1;')
        self.assertFalse(ok)


class TestEnterpriseConfig(unittest.TestCase):
    def test_flips_false_to_true(self):
        sample = 'config={secureVmFeaturesEnabled:!1}'
        result, ok = patch_enterprise_config.apply(sample)
        self.assertTrue(ok)
        self.assertIn('secureVmFeaturesEnabled:!0', result)

    def test_noop_when_not_false(self):
        sample = 'config={secureVmFeaturesEnabled:!0}'
        result, ok = patch_enterprise_config.apply(sample)
        self.assertTrue(ok)
        self.assertEqual(result, sample)


class TestApiHeaders(unittest.TestCase):
    def test_spoofs_platform_header(self):
        sample = '"Anthropic-Client-OS-Platform": "linux"'
        result, ok = patch_api_headers.apply(sample)
        self.assertTrue(ok)
        self.assertIn('"darwin"', result)


class TestBinaryManager(unittest.TestCase):
    SAMPLE = (
        'getHostPlatform(){const e=process.arch;'
        'if(process.platform==="darwin")return e==="arm64"?"darwin-arm64":"darwin-x64";'
        'if(process.platform==="win32")return e==="arm64"?"win32-arm64":"win32-x64";'
        'throw new Error(`Unsupported platform: ${process.platform}-${e}`)}'
    )

    def test_adds_linux_platform(self):
        result, ok = patch_binary_manager.apply(self.SAMPLE)
        self.assertTrue(ok)
        self.assertIn('linux', result)
        self.assertIn('linux-x64', result)
        self.assertIn('linux-arm64', result)


class TestBinaryResolution(unittest.TestCase):
    SAMPLE = 'async getLocalBinaryPath(){return this.localBinaryInitPromise&&await this.localBinaryInitPromise,this.localBinaryPath}'

    def test_adds_linux_paths(self):
        result, ok = patch_binary_resolution.apply(self.SAMPLE)
        self.assertTrue(ok)
        self.assertIn('/usr/bin/claude', result)
        self.assertIn('process.platform==="linux"', result)


class TestCoworkInit(unittest.TestCase):
    def test_injects_init_code(self):
        result, ok = inject_cowork_init.apply('const app = require("electron");')
        self.assertTrue(ok)
        self.assertIn('cowork-linux', result)
        self.assertIn('initializeCowork', result)

    def test_skips_if_already_injected(self):
        sample = '// cowork-linux already here\nconst x = 1;'
        result, ok = inject_cowork_init.apply(sample)
        self.assertTrue(ok)
        self.assertEqual(result, sample)


if __name__ == '__main__':
    unittest.main()
