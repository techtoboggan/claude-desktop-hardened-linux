/**
 * File watch manager for Cowork sessions.
 * Monitors session working directories for changes and notifies the renderer.
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { getSessionMountDir } = require('./dirs');

class FileWatchManager {
  constructor() {
    this._watchers = new Map(); // sessionId → FSWatcher
    this._callbacks = new Map(); // sessionId → callback
  }

  /**
   * Start watching a session's mount directory.
   */
  watch(sessionId, callback) {
    this.unwatch(sessionId); // Clean up any existing watcher

    const mountDir = getSessionMountDir(sessionId);

    try {
      if (!fs.existsSync(mountDir)) {
        fs.mkdirSync(mountDir, { recursive: true, mode: 0o700 });
      }

      const watcher = fs.watch(mountDir, { recursive: true }, (eventType, filename) => {
        if (callback) {
          callback({
            sessionId,
            eventType,
            filename,
            timestamp: new Date().toISOString(),
          });
        }
      });

      watcher.on('error', (err) => {
        console.error(`[cowork-linux] File watch error for ${sessionId}:`, err.message);
        this.unwatch(sessionId);
      });

      this._watchers.set(sessionId, watcher);
      this._callbacks.set(sessionId, callback);

      return true;
    } catch (err) {
      console.error(`[cowork-linux] Failed to start file watch: ${err.message}`);
      return false;
    }
  }

  /**
   * Stop watching a session's directory.
   */
  unwatch(sessionId) {
    const watcher = this._watchers.get(sessionId);
    if (watcher) {
      watcher.close();
      this._watchers.delete(sessionId);
      this._callbacks.delete(sessionId);
    }
  }

  /**
   * Stop all watchers.
   */
  unwatchAll() {
    for (const sessionId of this._watchers.keys()) {
      this.unwatch(sessionId);
    }
  }
}

module.exports = { FileWatchManager };
