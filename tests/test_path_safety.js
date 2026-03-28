/**
 * Tests for path safety checks in claude-swift-stub and dirs.js
 *
 * Run: node --test tests/test_path_safety.js
 */

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

// We need to extract isPathSafe from dirs.js (it's exported)
const { isPathSafe } = require('../stubs/cowork/dirs');

describe('isPathSafe (dirs.js)', () => {
  it('blocks path traversal', () => {
    assert.ok(!isPathSafe('/home/user/../etc/passwd'));
    assert.ok(!isPathSafe('../../etc/shadow'));
    assert.ok(!isPathSafe('/tmp/test/../../etc/passwd'));
  });

  it('blocks .ssh directory', () => {
    assert.ok(!isPathSafe('/home/user/.ssh/id_rsa'));
    assert.ok(!isPathSafe('/home/user/.ssh'));
  });

  it('blocks .gnupg directory', () => {
    assert.ok(!isPathSafe('/home/user/.gnupg/private-keys-v1.d'));
    assert.ok(!isPathSafe('/home/user/.gnupg'));
  });

  it('blocks .aws directory', () => {
    assert.ok(!isPathSafe('/home/user/.aws/credentials'));
  });

  it('blocks .kube directory', () => {
    assert.ok(!isPathSafe('/home/user/.kube/config'));
  });

  it('blocks .docker directory', () => {
    assert.ok(!isPathSafe('/home/user/.docker/config.json'));
  });

  it('blocks persistence vectors', () => {
    assert.ok(!isPathSafe('/home/user/.bashrc'));
    assert.ok(!isPathSafe('/home/user/.bash_profile'));
    assert.ok(!isPathSafe('/home/user/.profile'));
    assert.ok(!isPathSafe('/home/user/.zshrc'));
    assert.ok(!isPathSafe('/home/user/.config/autostart/malware.desktop'));
  });

  it('allows normal paths', () => {
    assert.ok(isPathSafe('/home/user/projects/myapp/src/main.js'));
    assert.ok(isPathSafe('/tmp/work/file.txt'));
    assert.ok(isPathSafe('/home/user/Documents/report.pdf'));
  });

  it('rejects null/undefined/empty', () => {
    assert.ok(!isPathSafe(null));
    assert.ok(!isPathSafe(undefined));
    assert.ok(!isPathSafe(''));
  });
});
