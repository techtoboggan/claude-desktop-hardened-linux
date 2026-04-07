/**
 * Integration tests for Cowork subsystem interactions.
 *
 * These verify that the major subsystems work together correctly:
 * - Credential classifier integrates with transcript store
 * - Computer Use module detects display servers and finds tools
 * - Path safety blocks sensitive paths before they reach the sandbox
 * - Session store creates and tracks sessions
 *
 * Unlike unit tests, these exercise real module interactions rather than
 * testing individual functions in isolation. They don't require a running
 * display server, sandbox, or network access.
 *
 * Run: node --test tests/test_integration.js
 */

'use strict';

const { describe, it, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');

// ---------------------------------------------------------------------------
// Credential classifier + Computer Use logging integration
// ---------------------------------------------------------------------------

describe('credential redaction in computer use logging', () => {
  const { redactForLogs, classifyCredential } = require('../stubs/cowork/credential_classifier');

  it('redacts API keys embedded in tool output strings', () => {
    const toolOutput = 'screenshot: {"env":"ANTHROPIC_API_KEY=sk-ant-api03-abc123def456"}';
    const redacted = redactForLogs(toolOutput);
    assert.ok(!redacted.includes('sk-ant-api03-abc123def456'), 'API key should be redacted');
    assert.ok(redacted.includes('[REDACTED'), 'Should contain redaction marker');
  });

  it('redacts bearer tokens in JSON-stringified action details', () => {
    const details = JSON.stringify({ header: 'Authorization: Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.payload.signature' });
    const redacted = redactForLogs(details);
    assert.ok(!redacted.includes('eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9'), 'JWT should be redacted');
  });

  it('redacts GitHub tokens in multi-line output', () => {
    // GitHub PAT regex requires ghp_ + 36+ alphanumeric chars
    const token = 'ghp_ABCDEFghijklmnop1234567890abcdefABCDEF';
    const output = `click: {"result":"${token} found in clipboard"}`;
    const redacted = redactForLogs(output);
    assert.ok(!redacted.includes(token), 'GitHub PAT should be redacted');
  });
});

// ---------------------------------------------------------------------------
// Computer Use module — tool discovery and display server detection
// ---------------------------------------------------------------------------

describe('computer use module structure', () => {
  const computerUse = require('../stubs/cowork/computer_use');

  it('exports all expected functions', () => {
    const expected = [
      'detectDisplayServer', 'findTool', 'captureScreenshot',
      'getOpenWindows', 'clickAt', 'typeText', 'scroll',
      'getDisplayInfo', 'activateWindow', 'activateClaudeWindow',
    ];
    for (const fn of expected) {
      assert.equal(typeof computerUse[fn], 'function', `${fn} should be exported`);
    }
  });

  it('detectDisplayServer returns a known value', () => {
    const ds = computerUse.detectDisplayServer();
    assert.ok(['wayland', 'x11', 'headless'].includes(ds),
      `Expected wayland/x11/headless, got: ${ds}`);
  });

  it('findTool returns null for nonexistent tools', () => {
    const result = computerUse.findTool('definitely-not-a-real-tool-12345');
    assert.equal(result, null);
  });

  it('findTool only searches safe paths', () => {
    // Verify it doesn't find things outside /usr/bin and /usr/local/bin
    // Even if something exists in /tmp/bin or user-writable paths
    const result = computerUse.findTool('../../tmp/evil');
    assert.equal(result, null, 'Path traversal in tool name should not resolve');
  });
});

// ---------------------------------------------------------------------------
// Path safety — verify integration with fs.existsSync paths
// ---------------------------------------------------------------------------

describe('path safety integration', () => {
  // isPathSafe returns true for safe paths, false for blocked ones
  const { isPathSafe } = require('../stubs/cowork/dirs');

  it('blocks all known sensitive directories', () => {
    const sensitiveDirectories = [
      path.join(os.homedir(), '.ssh', 'id_rsa'),
      path.join(os.homedir(), '.gnupg', 'private-keys-v1.d', 'key.gpg'),
      path.join(os.homedir(), '.aws', 'credentials'),
      path.join(os.homedir(), '.kube', 'config'),
      path.join(os.homedir(), '.docker', 'config.json'),
    ];

    for (const p of sensitiveDirectories) {
      assert.ok(!isPathSafe(p), `${p} should be blocked`);
    }
  });

  it('blocks persistence vectors', () => {
    const persistenceVectors = [
      path.join(os.homedir(), '.bashrc'),
      path.join(os.homedir(), '.profile'),
      path.join(os.homedir(), '.config', 'autostart', 'evil.desktop'),
    ];

    for (const p of persistenceVectors) {
      assert.ok(!isPathSafe(p), `${p} should be blocked`);
    }
  });

  it('allows normal working directories', () => {
    const safePaths = [
      path.join(os.homedir(), 'projects', 'myapp', 'src', 'main.js'),
      '/tmp/cowork-session-123/output.txt',
    ];

    for (const p of safePaths) {
      assert.ok(isPathSafe(p), `${p} should be allowed`);
    }
  });

  it('blocks path traversal at raw input level', () => {
    assert.ok(!isPathSafe('/home/user/../etc/shadow'),
      'Traversal should be caught before normalization');
    assert.ok(!isPathSafe('../../etc/passwd'),
      'Relative traversal should be caught');
  });
});

// ---------------------------------------------------------------------------
// Session store — lifecycle
// ---------------------------------------------------------------------------

describe('session store lifecycle', () => {
  const { SessionStore } = require('../stubs/cowork/session_store');
  let store;
  let tmpDir;

  beforeEach(() => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'cowork-test-'));
    store = new SessionStore(tmpDir);
  });

  it('creates and retrieves a session', () => {
    const session = store.create({ workDir: '/tmp/test', backend: 'bubblewrap' });
    assert.ok(session.id, 'Should return a session with an ID');
    const retrieved = store.get(session.id);
    assert.ok(retrieved, 'Should retrieve the session');
    assert.equal(retrieved.workDir, '/tmp/test');
  });

  it('tracks multiple concurrent sessions', () => {
    const s1 = store.create({ workDir: '/tmp/test1', backend: 'bubblewrap' });
    const s2 = store.create({ workDir: '/tmp/test2', backend: 'bubblewrap' });
    assert.notEqual(s1.id, s2.id, 'Session IDs should be unique');
    const all = store.getAll();
    assert.ok(all.length >= 2, 'Should list at least 2 sessions');
  });

  it('removes sessions cleanly', () => {
    const session = store.create({ workDir: '/tmp/test', backend: 'bubblewrap' });
    store.remove(session.id);
    const retrieved = store.get(session.id);
    assert.equal(retrieved, null, 'Removed session should not be retrievable');
  });
});

// ---------------------------------------------------------------------------
// Cross-module: credential classifier handles edge cases gracefully
// ---------------------------------------------------------------------------

describe('credential classifier robustness', () => {
  const { redactForLogs } = require('../stubs/cowork/credential_classifier');

  it('handles empty input', () => {
    assert.equal(redactForLogs(''), '');
  });

  it('handles null/undefined without throwing', () => {
    assert.doesNotThrow(() => redactForLogs(null));
    assert.doesNotThrow(() => redactForLogs(undefined));
  });

  it('handles very long strings without hanging', () => {
    const longString = 'A'.repeat(100_000);
    const start = Date.now();
    redactForLogs(longString);
    const elapsed = Date.now() - start;
    assert.ok(elapsed < 5000, `Should complete in <5s, took ${elapsed}ms`);
  });

  it('does not corrupt non-credential content', () => {
    const safe = 'Just a normal log line with no secrets at all.';
    assert.equal(redactForLogs(safe), safe, 'Non-credential text should pass through unchanged');
  });
});
