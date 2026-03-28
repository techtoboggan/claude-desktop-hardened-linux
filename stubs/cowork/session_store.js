/**
 * Persistent session store for Cowork sessions.
 * Saves session metadata to disk so sessions can survive app restarts.
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { SESSIONS_DIR } = require('./dirs');

const STORE_FILE = path.join(SESSIONS_DIR, 'sessions.json');

class SessionStore {
  constructor() {
    this._sessions = new Map();
    this._load();
  }

  _load() {
    try {
      if (fs.existsSync(STORE_FILE)) {
        const data = JSON.parse(fs.readFileSync(STORE_FILE, 'utf8'));
        if (Array.isArray(data)) {
          for (const session of data) {
            this._sessions.set(session.id, session);
          }
        }
      }
    } catch (err) {
      console.error('[cowork-linux] Failed to load session store:', err.message);
    }
  }

  _save() {
    try {
      const dir = path.dirname(STORE_FILE);
      fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
      const data = Array.from(this._sessions.values());
      fs.writeFileSync(STORE_FILE, JSON.stringify(data, null, 2), { mode: 0o600 });
    } catch (err) {
      console.error('[cowork-linux] Failed to save session store:', err.message);
    }
  }

  create(sessionData) {
    const session = {
      id: sessionData.id || this._generateId(),
      name: sessionData.name || 'Untitled',
      workDir: sessionData.workDir || process.env.HOME,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
      status: 'active',
      ...sessionData,
    };
    this._sessions.set(session.id, session);
    this._save();
    return session;
  }

  get(sessionId) {
    return this._sessions.get(sessionId) || null;
  }

  getAll() {
    return Array.from(this._sessions.values());
  }

  getActive() {
    return this.getAll().filter(s => s.status === 'active');
  }

  update(sessionId, updates) {
    const session = this._sessions.get(sessionId);
    if (!session) return null;

    Object.assign(session, updates, { updatedAt: new Date().toISOString() });
    this._sessions.set(sessionId, session);
    this._save();
    return session;
  }

  archive(sessionId) {
    return this.update(sessionId, { status: 'archived' });
  }

  remove(sessionId) {
    const removed = this._sessions.delete(sessionId);
    if (removed) this._save();
    return removed;
  }

  _generateId() {
    const crypto = require('crypto');
    return `session_${crypto.randomBytes(16).toString('hex')}`;
  }
}

module.exports = { SessionStore };
