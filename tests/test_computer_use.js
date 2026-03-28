/**
 * Tests for computer_use.js — display server detection and tool finding.
 *
 * Run: node --test tests/test_computer_use.js
 */

const { describe, it, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');

// We need to test detectDisplayServer and findTool without actually
// running grim/scrot/xdotool. We test the detection logic and tool lookup.

describe('detectDisplayServer', () => {
  let origEnv;

  beforeEach(() => {
    origEnv = { ...process.env };
  });

  afterEach(() => {
    // Restore environment
    process.env = origEnv;
    // Clear require cache so module re-reads env
    delete require.cache[require.resolve('../stubs/cowork/computer_use')];
  });

  it('returns wayland when CLAUDE_DISPLAY_SERVER is set', () => {
    process.env.CLAUDE_DISPLAY_SERVER = 'wayland';
    const { detectDisplayServer } = require('../stubs/cowork/computer_use');
    assert.equal(detectDisplayServer(), 'wayland');
  });

  it('returns x11 when CLAUDE_DISPLAY_SERVER is x11', () => {
    process.env.CLAUDE_DISPLAY_SERVER = 'x11';
    const { detectDisplayServer } = require('../stubs/cowork/computer_use');
    assert.equal(detectDisplayServer(), 'x11');
  });

  it('detects wayland from WAYLAND_DISPLAY', () => {
    delete process.env.CLAUDE_DISPLAY_SERVER;
    process.env.WAYLAND_DISPLAY = 'wayland-0';
    const { detectDisplayServer } = require('../stubs/cowork/computer_use');
    assert.equal(detectDisplayServer(), 'wayland');
  });

  it('detects wayland from XDG_SESSION_TYPE', () => {
    delete process.env.CLAUDE_DISPLAY_SERVER;
    delete process.env.WAYLAND_DISPLAY;
    process.env.XDG_SESSION_TYPE = 'wayland';
    const { detectDisplayServer } = require('../stubs/cowork/computer_use');
    assert.equal(detectDisplayServer(), 'wayland');
  });

  it('detects x11 from DISPLAY', () => {
    delete process.env.CLAUDE_DISPLAY_SERVER;
    delete process.env.WAYLAND_DISPLAY;
    delete process.env.XDG_SESSION_TYPE;
    process.env.DISPLAY = ':0';
    const { detectDisplayServer } = require('../stubs/cowork/computer_use');
    assert.equal(detectDisplayServer(), 'x11');
  });

  it('returns headless when no display vars set', () => {
    delete process.env.CLAUDE_DISPLAY_SERVER;
    delete process.env.WAYLAND_DISPLAY;
    delete process.env.XDG_SESSION_TYPE;
    delete process.env.DISPLAY;
    const { detectDisplayServer } = require('../stubs/cowork/computer_use');
    assert.equal(detectDisplayServer(), 'headless');
  });
});

describe('findTool', () => {
  it('finds tools in /usr/bin', () => {
    const { findTool } = require('../stubs/cowork/computer_use');
    // bash should always be in /usr/bin
    const result = findTool('bash');
    assert.ok(result === '/usr/bin/bash' || result === '/usr/local/bin/bash',
      `Expected /usr/bin/bash or /usr/local/bin/bash, got ${result}`);
  });

  it('returns null for nonexistent tools', () => {
    const { findTool } = require('../stubs/cowork/computer_use');
    assert.equal(findTool('definitely_not_a_real_tool_12345'), null);
  });

  it('does not search arbitrary PATH directories', () => {
    const { findTool } = require('../stubs/cowork/computer_use');
    // Even if something is in PATH via ~/.local/bin, findTool should only check /usr/bin and /usr/local/bin
    const result = findTool('bash');
    if (result) {
      assert.ok(
        result.startsWith('/usr/bin/') || result.startsWith('/usr/local/bin/'),
        `Tool found outside allowed paths: ${result}`
      );
    }
  });
});
