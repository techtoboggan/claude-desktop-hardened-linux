/**
 * Permission layer for Computer Use on Linux.
 *
 * Unlike other platforms that auto-grant, this implementation shows a
 * native dialog and requires explicit user approval. Grants are scoped
 * to the current app session — they reset on restart.
 */

'use strict';

const { dialog, BrowserWindow } = require('electron');

// Session-only grant cache: "sessionId:permissionType" → timestamp
const sessionGrants = new Map();

const PERMISSION_LABELS = {
  screenRecording: 'Screen Recording (screenshot capture)',
  accessibility: 'Input Automation (click, type, scroll)',
  windowListing: 'Window Listing',
};

/**
 * Request a permission grant, showing a dialog if not already granted.
 */
async function requestPermission(permissionType, sessionId) {
  const key = `${sessionId || 'default'}:${permissionType}`;

  if (sessionGrants.has(key)) {
    return { granted: true };
  }

  const label = PERMISSION_LABELS[permissionType] || permissionType;
  const win = BrowserWindow.getFocusedWindow();

  const result = await dialog.showMessageBox(win, {
    type: 'question',
    buttons: ['Allow', 'Deny'],
    defaultId: 1,
    cancelId: 1,
    title: 'Computer Use Permission',
    message: `Claude is requesting: ${label}`,
    detail: [
      `This will allow Claude to interact with your desktop.`,
      ``,
      `Session: ${sessionId || 'default'}`,
      `Permission: ${permissionType}`,
      ``,
      `This grant lasts until you close Claude Desktop.`,
    ].join('\n'),
  });

  const granted = result.response === 0;
  if (granted) {
    sessionGrants.set(key, Date.now());
    console.log(`[cowork-linux] Permission granted: ${permissionType} for session ${sessionId}`);
  } else {
    console.log(`[cowork-linux] Permission denied: ${permissionType} for session ${sessionId}`);
  }

  return { granted };
}

/**
 * Check current grant state (without prompting).
 */
function getState() {
  const hasScreenGrant = Array.from(sessionGrants.keys()).some(k => k.endsWith(':screenRecording'));
  const hasAccessGrant = Array.from(sessionGrants.keys()).some(k => k.endsWith(':accessibility'));
  return {
    screenRecording: hasScreenGrant,
    accessibility: hasAccessGrant,
  };
}

/**
 * List all active grants.
 */
function getCurrentSessionGrants() {
  return Array.from(sessionGrants.entries()).map(([key, timestamp]) => ({
    key,
    grantedAt: new Date(timestamp).toISOString(),
  }));
}

/**
 * Revoke a specific grant.
 */
function revokeGrant(key) {
  sessionGrants.delete(key);
}

/**
 * Revoke all grants for a session.
 */
function revokeAllForSession(sessionId) {
  for (const key of sessionGrants.keys()) {
    if (key.startsWith(`${sessionId}:`)) {
      sessionGrants.delete(key);
    }
  }
}

module.exports = {
  requestPermission,
  getState,
  getCurrentSessionGrants,
  revokeGrant,
  revokeAllForSession,
};
