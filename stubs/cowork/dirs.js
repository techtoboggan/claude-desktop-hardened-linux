/**
 * XDG-compliant directory management for Cowork sessions on Linux.
 * Handles path translation between VM-style paths and host paths.
 */

'use strict';

const path = require('path');
const fs = require('fs');
const os = require('os');

const XDG_CONFIG = process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config');
const XDG_DATA = process.env.XDG_DATA_HOME || path.join(os.homedir(), '.local', 'share');
const XDG_STATE = process.env.XDG_STATE_HOME || path.join(os.homedir(), '.local', 'state');

const CLAUDE_CONFIG = path.join(XDG_CONFIG, 'Claude');
const SESSIONS_DIR = path.join(CLAUDE_CONFIG, 'local-agent-mode-sessions');
const COWORK_STATE = path.join(XDG_STATE, 'claude-cowork');
const COWORK_LOGS = path.join(COWORK_STATE, 'logs');

/**
 * Ensure all required directories exist with proper permissions.
 */
function ensureDirectories() {
  const dirs = [
    CLAUDE_CONFIG,
    SESSIONS_DIR,
    path.join(SESSIONS_DIR, 'sessions'),
    COWORK_STATE,
    COWORK_LOGS,
  ];

  for (const dir of dirs) {
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  }
}

/**
 * Get the session directory for a given session ID.
 */
function getSessionDir(sessionId) {
  return path.join(SESSIONS_DIR, 'sessions', sessionId);
}

/**
 * Get the mount directory for a session.
 */
function getSessionMountDir(sessionId) {
  return path.join(getSessionDir(sessionId), 'mnt');
}

/**
 * Translate a VM-style path to a host path.
 */
function vmToHostPath(vmPath) {
  if (!vmPath || typeof vmPath !== 'string') return vmPath;

  // /sessions/<name>/mnt/<rest>
  const match = vmPath.match(/^\/sessions\/([^/]+)\/mnt\/(.*)$/);
  if (match) {
    return path.join(SESSIONS_DIR, 'sessions', match[1], 'mnt', match[2]);
  }

  // /home/<user>/... → pass through
  if (vmPath.startsWith('/home/') || vmPath.startsWith(os.homedir())) {
    return vmPath;
  }

  return vmPath;
}

/**
 * Check if a path is safe (no traversal, no sensitive dirs).
 */
function isPathSafe(p) {
  if (!p || typeof p !== 'string') return false;
  const normalized = path.normalize(p);
  if (normalized.includes('..')) return false;

  const blockedDirs = [
    '.ssh', '.gnupg', '.aws', '.kube', '.docker',
    '.bashrc', '.bash_profile', '.profile', '.zshrc',
    '.config/autostart', '.local/share/autostart',
    'cron', '.pam_environment',
  ];
  for (const dir of blockedDirs) {
    if (normalized.includes(path.sep + dir + path.sep) ||
        normalized.endsWith(path.sep + dir)) {
      return false;
    }
  }
  return true;
}

module.exports = {
  XDG_CONFIG,
  XDG_DATA,
  XDG_STATE,
  CLAUDE_CONFIG,
  SESSIONS_DIR,
  COWORK_STATE,
  COWORK_LOGS,
  ensureDirectories,
  getSessionDir,
  getSessionMountDir,
  vmToHostPath,
  isPathSafe,
};
