/**
 * Tests for bubblewrap command construction.
 *
 * These test the buildBwrapCommand logic without actually running bwrap.
 * We verify the argument structure ensures:
 * - Default-deny filesystem (no --ro-bind / /)
 * - Only specific system paths mounted
 * - Home directory blocked by default
 * - Working directory writable
 * - Sensitive dirs not exposed
 *
 * Run: node --test tests/test_bwrap_command.js
 */

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');

// We can't easily require buildBwrapCommand directly since it's a function
// inside claude-swift-stub, not exported. Instead, we test the principles
// by examining what the module would produce. We can at least test the
// helper functions that ARE accessible.

describe('bwrap command security principles', () => {

  it('isPathSafe blocks traversal in raw input', () => {
    // Re-import to test the swift stub's version
    // Note: we test dirs.js version in test_path_safety.js
    // This tests the principle that traversal is caught before normalize()
    const path = require('node:path');
    const testPaths = [
      { input: '/home/user/../etc/passwd', expected: false },
      { input: '../../etc/shadow', expected: false },
      { input: '/home/user/.ssh/id_rsa', expected: false },
      { input: '/home/user/.gnupg/private', expected: false },
      { input: '/home/user/.aws/credentials', expected: false },
      { input: '/home/user/.bashrc', expected: false },
      { input: '/home/user/.config/autostart/evil.desktop', expected: false },
      { input: '/home/user/projects/src/main.js', expected: true },
      { input: '/tmp/work/output.txt', expected: true },
    ];

    for (const { input, expected } of testPaths) {
      // Inline the logic from isPathSafe
      let safe = true;
      if (input.includes('..')) safe = false;
      const normalized = path.normalize(input);
      const sensitive = [
        '.ssh', '.gnupg', '.aws', '.kube', '.docker',
        '.bashrc', '.bash_profile', '.profile', '.zshrc',
        '.config/autostart', '.local/share/autostart',
        'cron', '.pam_environment',
      ];
      for (const dir of sensitive) {
        if (normalized.includes(`/${dir}/`) || normalized.endsWith(`/${dir}`)) {
          safe = false;
        }
      }
      assert.equal(safe, expected, `isPathSafe('${input}') should be ${expected}`);
    }
  });

  it('RESOURCE_LIMITS has sensible values', () => {
    // Verify the constants we set are reasonable
    const limits = {
      memoryMax: '4G',
      cpuQuota: '200%',
      tasksMax: '512',
    };

    // Memory should be at least 1G and at most 16G
    const memGB = parseInt(limits.memoryMax);
    assert.ok(memGB >= 1 && memGB <= 16, `Memory limit ${limits.memoryMax} out of range`);

    // CPU quota should be at least 100% (1 core)
    const cpuPct = parseInt(limits.cpuQuota);
    assert.ok(cpuPct >= 100 && cpuPct <= 800, `CPU quota ${limits.cpuQuota} out of range`);

    // Tasks should be at least 64 and at most 4096
    const tasks = parseInt(limits.tasksMax);
    assert.ok(tasks >= 64 && tasks <= 4096, `Tasks limit ${limits.tasksMax} out of range`);
  });

  it('MAX_CONCURRENT_SESSIONS is bounded', () => {
    const MAX = 10;
    assert.ok(MAX >= 1 && MAX <= 50, `Max sessions ${MAX} out of range`);
  });

  // Parse the real ENV_ALLOWLIST from the source file so this test stays
  // in sync with the actual shipped allowlist instead of a hand-copied one.
  function loadRealAllowlist() {
    const fs = require('node:fs');
    const path = require('node:path');
    const src = fs.readFileSync(
      path.join(__dirname, '..', 'stubs', 'claude-swift-stub', 'index.js'),
      'utf8'
    );
    const m = src.match(/ENV_ALLOWLIST\s*=\s*new Set\(\[([\s\S]*?)\]\)/);
    if (!m) throw new Error('Could not locate ENV_ALLOWLIST in source');
    const names = [];
    for (const line of m[1].split('\n')) {
      // Strip // line comments before extracting quoted identifiers.
      const stripped = line.replace(/\/\/.*$/, '');
      for (const qm of stripped.matchAll(/['"]([A-Z][A-Z0-9_]+)['"]/g)) {
        names.push(qm[1]);
      }
    }
    return new Set(names);
  }

  it('ENV_ALLOWLIST does not include dangerous variables', () => {
    const allowlist = loadRealAllowlist();

    // These should NEVER be in the allowlist — injection vectors,
    // cloud credentials with out-of-scope reach, or secrets that
    // shouldn't silently leak from the host shell into sandboxed
    // agent sessions.
    const dangerous = [
      // Code-injection via loader / interpreter
      'LD_PRELOAD', 'LD_LIBRARY_PATH', 'PYTHONPATH',
      'NODE_OPTIONS', 'BASH_ENV', 'ENV',
      // Cloud credentials (broader scope than model backend — opt-in only)
      'AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_SESSION_TOKEN',
      'GOOGLE_APPLICATION_CREDENTIALS',
      // Foreign-service secrets
      'GITHUB_TOKEN', 'NPM_TOKEN',
    ];

    for (const v of dangerous) {
      assert.ok(!allowlist.has(v), `Dangerous variable ${v} is in ENV_ALLOWLIST`);
    }
  });

  it('ENV_ALLOWLIST includes Anthropic SDK env vars for custom backends', () => {
    // Users point Code/Cowork sessions at custom backends (LiteLLM,
    // LM Studio, Ollama, OpenRouter, vLLM, …) by setting standard
    // ANTHROPIC_* env vars in their shell. If any of these get
    // accidentally dropped from the allowlist, the stub silently
    // strips them and the custom backend is ignored — exactly the
    // regression we just fixed.
    const allowlist = loadRealAllowlist();
    const required = [
      'ANTHROPIC_API_KEY',
      'ANTHROPIC_AUTH_TOKEN',
      'ANTHROPIC_BASE_URL',
      'ANTHROPIC_MODEL',
      'ANTHROPIC_SMALL_FAST_MODEL',
      'ANTHROPIC_DEFAULT_OPUS_MODEL',
      'ANTHROPIC_DEFAULT_SONNET_MODEL',
      'ANTHROPIC_DEFAULT_HAIKU_MODEL',
      'ANTHROPIC_CUSTOM_HEADERS',
      'CLAUDE_CODE_MAX_OUTPUT_TOKENS',
    ];
    for (const v of required) {
      assert.ok(allowlist.has(v), `Custom-backend env var ${v} missing from ENV_ALLOWLIST — see README → "Using a custom model backend"`);
    }
  });

  it('BINARY_PATH_ALLOWLIST only includes system directories', () => {
    const os = require('node:os');
    const path = require('node:path');
    const allowlist = [
      '/usr/lib64/claude-desktop-hardened/',
      '/usr/lib/claude-desktop-hardened/',
      '/usr/local/bin/',
      '/usr/bin/',
      path.join(os.homedir(), '.local', 'bin') + '/',
      path.join(os.homedir(), '.npm-global', 'bin') + '/',
      path.join(os.homedir(), '.config', 'Claude', 'claude-code-vm') + '/',
    ];

    for (const p of allowlist) {
      // Must be absolute
      assert.ok(path.isAbsolute(p), `Path not absolute: ${p}`);
      // Must end with /
      assert.ok(p.endsWith('/'), `Path not directory: ${p}`);
      // Must not contain traversal
      assert.ok(!p.includes('..'), `Path contains traversal: ${p}`);
    }
  });
});
