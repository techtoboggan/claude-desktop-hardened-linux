/**
 * Session Orchestrator — coordinates Cowork session lifecycle.
 *
 * This is the main coordinator that sits between the Electron IPC handlers
 * and the SwiftAddonStub (process spawner). It manages session creation,
 * environment preparation, mount setup, and teardown.
 */

'use strict';

const path = require('path');
const fs = require('fs');
const os = require('os');
const { SessionStore } = require('./session_store');
const { ensureDirectories, getSessionDir, getSessionMountDir, vmToHostPath } = require('./dirs');
const { redactForLogs } = require('./credential_classifier');

class SessionOrchestrator {
  constructor(swiftStub) {
    this._swift = swiftStub;
    this._store = new SessionStore();
    this._activeHandles = new Map(); // sessionId → process handle
    ensureDirectories();
  }

  /**
   * Start a new Cowork session.
   *
   * @param {object} options
   * @param {string} options.name - Session display name
   * @param {string} options.workDir - Working directory
   * @param {string[]} options.mountPaths - Host paths to mount into session
   * @param {string} options.oauthToken - Claude OAuth token
   * @param {string[]} options.args - Extra CLI arguments
   * @returns {object} Session metadata
   */
  async start(options = {}) {
    const session = this._store.create({
      name: options.name,
      workDir: options.workDir || os.homedir(),
      mountPaths: options.mountPaths || [],
    });

    console.log(`[cowork-linux] Starting session: ${session.id} (${session.name})`);

    // Ensure session directories
    const sessionDir = getSessionDir(session.id);
    const mountDir = getSessionMountDir(session.id);
    fs.mkdirSync(mountDir, { recursive: true, mode: 0o700 });

    // Set up mounts (symlinks from session dir to host paths)
    for (const hostPath of (options.mountPaths || [])) {
      this._swift.mountPath(session.id, hostPath);
    }

    // Build CLI arguments
    const args = [
      '--print-only',  // JSON output mode
      ...(options.args || []),
    ];

    // Build environment
    const env = {};
    if (options.oauthToken) {
      env.CLAUDE_CODE_OAUTH_TOKEN = options.oauthToken;
    }

    // Spawn the Claude Code CLI process.
    // vm.spawn signature: (sessionId, processName, command, args, cwd, env,
    //   additionalMounts, isResume, allowedDomains, sharedCwdPath, oneShot)
    const workDir = options.workDir || os.homedir();
    const handle = this._swift.spawn(
      session.id,
      session.name,        // processName
      'claude',            // command (resolved by stub)
      args,                // CLI arguments
      workDir,             // cwd
      env,                 // environment
      options.mountPaths,  // additionalMounts
      false,               // isResume
      null,                // allowedDomains
      null,                // sharedCwdPath
      false                // oneShot
    );

    this._activeHandles.set(session.id, handle);
    this._store.update(session.id, { status: 'running', pid: handle.pid });

    return {
      sessionId: session.id,
      name: session.name,
      pid: handle.pid,
      status: 'running',
    };
  }

  /**
   * Stop a running session.
   */
  async stop(sessionId) {
    console.log(`[cowork-linux] Stopping session: ${sessionId}`);

    const handle = this._activeHandles.get(sessionId);
    if (handle) {
      handle.kill('SIGTERM');
      this._activeHandles.delete(sessionId);
    }

    this._store.update(sessionId, { status: 'stopped' });
    return true;
  }

  /**
   * Send a message to a running session.
   */
  async sendMessage(sessionId, message) {
    const handle = this._activeHandles.get(sessionId);
    if (!handle) {
      throw new Error(`No active session: ${sessionId}`);
    }

    handle.write(JSON.stringify(message) + '\n');
    return true;
  }

  /**
   * Archive a session (mark as archived, keep data).
   */
  async archive(sessionId) {
    await this.stop(sessionId);
    this._store.archive(sessionId);
    return true;
  }

  /**
   * Get session info.
   */
  getSession(sessionId) {
    const session = this._store.get(sessionId);
    if (session) {
      session.isRunning = this._activeHandles.has(sessionId);
    }
    return session;
  }

  /**
   * List all sessions.
   */
  listSessions() {
    const sessions = this._store.getAll();
    return sessions.map(s => ({
      ...s,
      isRunning: this._activeHandles.has(s.id),
    }));
  }

  /**
   * Resume a previously stopped session.
   */
  async resume(sessionId, options = {}) {
    const session = this._store.get(sessionId);
    if (!session) {
      throw new Error(`Session not found: ${sessionId}`);
    }

    return this.start({
      ...session,
      ...options,
      name: session.name,
      workDir: session.workDir,
      mountPaths: session.mountPaths,
    });
  }

  /**
   * Handle output from a session (for transcript storage, IPC forwarding, etc.)
   */
  _onSessionOutput(sessionId, stream, data) {
    // This can be extended to:
    // - Write to transcript store
    // - Forward to renderer via IPC
    // - Log to file
    if (process.env.COWORK_DEBUG) {
      const { redactForLogs } = require('./credential_classifier');
      console.log(`[cowork-linux] [${sessionId}] [${stream}] ${redactForLogs(data.slice(0, 200))}`);
    }
  }

  /**
   * Clean up all sessions (for app shutdown).
   */
  async shutdown() {
    console.log('[cowork-linux] Shutting down all sessions...');
    for (const [sessionId] of this._activeHandles) {
      await this.stop(sessionId);
    }
  }
}

module.exports = { SessionOrchestrator };
