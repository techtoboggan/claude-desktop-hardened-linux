/**
 * Tests for session_store.js — session ID generation and CRUD.
 *
 * Run: node --test tests/test_session_store.js
 */

const { describe, it, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');

describe('SessionStore', () => {
  let tmpDir;
  let SessionStore;

  beforeEach(() => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'claude-test-sessions-'));
    // Patch the module to use our temp dir
    delete require.cache[require.resolve('../stubs/cowork/session_store')];
    SessionStore = require('../stubs/cowork/session_store').SessionStore;
  });

  afterEach(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  });

  it('generates cryptographically random session IDs', () => {
    const store = new SessionStore(tmpDir);
    const session = store.create({ name: 'test' });
    // Should start with session_ and have 32 hex chars (16 bytes)
    assert.match(session.id, /^session_[0-9a-f]{32}$/,
      `Session ID not cryptographically random: ${session.id}`);
  });

  it('generates unique session IDs', () => {
    const store = new SessionStore(tmpDir);
    const ids = new Set();
    for (let i = 0; i < 100; i++) {
      const session = store.create({ name: `test-${i}` });
      assert.ok(!ids.has(session.id), `Duplicate session ID: ${session.id}`);
      ids.add(session.id);
    }
  });

  it('creates and retrieves sessions', () => {
    const store = new SessionStore(tmpDir);
    const session = store.create({ name: 'my-session', workDir: '/tmp/work' });
    assert.ok(session.id);
    assert.equal(session.name, 'my-session');

    const retrieved = store.get(session.id);
    assert.equal(retrieved.id, session.id);
    assert.equal(retrieved.name, 'my-session');
  });

  it('lists all sessions via getAll', () => {
    const store = new SessionStore(tmpDir);
    store.create({ name: 'session-1' });
    store.create({ name: 'session-2' });
    store.create({ name: 'session-3' });

    const list = store.getAll();
    assert.equal(list.length, 3);
  });

  it('removes sessions', () => {
    const store = new SessionStore(tmpDir);
    const session = store.create({ name: 'to-delete' });
    assert.ok(store.get(session.id));

    const removed = store.remove(session.id);
    assert.ok(removed);
    assert.equal(store.get(session.id), null);
  });

  it('returns false when removing nonexistent session', () => {
    const store = new SessionStore(tmpDir);
    const removed = store.remove('session_nonexistent');
    assert.ok(!removed);
  });
});
