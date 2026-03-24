/**
 * Transcript store for Cowork session conversations.
 * Persists conversation history to disk so sessions can be reviewed later.
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { getSessionDir } = require('./dirs');
const { redactForLogs } = require('./credential_classifier');

class TranscriptStore {
  constructor() {
    this._buffers = new Map(); // sessionId → message array
  }

  /**
   * Append a message to a session's transcript.
   */
  append(sessionId, role, content) {
    if (!this._buffers.has(sessionId)) {
      this._buffers.set(sessionId, []);
    }

    const entry = {
      timestamp: new Date().toISOString(),
      role,
      content: redactForLogs(content),
    };

    this._buffers.get(sessionId).push(entry);

    // Flush to disk periodically (every 10 messages)
    if (this._buffers.get(sessionId).length % 10 === 0) {
      this.flush(sessionId);
    }
  }

  /**
   * Get the full transcript for a session.
   */
  get(sessionId) {
    // Merge disk + in-memory
    const diskTranscript = this._readFromDisk(sessionId);
    const memTranscript = this._buffers.get(sessionId) || [];
    return [...diskTranscript, ...memTranscript];
  }

  /**
   * Flush in-memory transcript to disk.
   */
  flush(sessionId) {
    const buffer = this._buffers.get(sessionId);
    if (!buffer || buffer.length === 0) return;

    const sessionDir = getSessionDir(sessionId);
    const transcriptFile = path.join(sessionDir, 'transcript.jsonl');

    try {
      fs.mkdirSync(sessionDir, { recursive: true, mode: 0o700 });
      const lines = buffer.map(entry => JSON.stringify(entry)).join('\n') + '\n';
      fs.appendFileSync(transcriptFile, lines, { mode: 0o600 });
      this._buffers.set(sessionId, []);
    } catch (err) {
      console.error(`[cowork-linux] Failed to flush transcript: ${err.message}`);
    }
  }

  /**
   * Flush all sessions.
   */
  flushAll() {
    for (const sessionId of this._buffers.keys()) {
      this.flush(sessionId);
    }
  }

  _readFromDisk(sessionId) {
    const transcriptFile = path.join(getSessionDir(sessionId), 'transcript.jsonl');
    try {
      if (!fs.existsSync(transcriptFile)) return [];
      const content = fs.readFileSync(transcriptFile, 'utf8');
      return content.split('\n').filter(Boolean).map(line => {
        try { return JSON.parse(line); } catch (_) { return null; }
      }).filter(Boolean);
    } catch (_) {
      return [];
    }
  }
}

module.exports = { TranscriptStore };
