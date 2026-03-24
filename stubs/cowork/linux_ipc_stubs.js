/**
 * Linux-specific IPC stubs for platform features that don't exist on Linux.
 *
 * These handle IPC channels that reference macOS or Windows-specific
 * functionality (TCC permissions, Windows registry, etc.) and return
 * sensible defaults so the app doesn't crash.
 */

'use strict';

const { ipcMain } = require('electron');

/**
 * Register Linux-specific IPC stubs for platform features.
 */
function registerLinuxStubs() {
  // macOS TCC (Transparency, Consent, and Control) — always granted on Linux
  safeHandle('tcc:checkAccess', async () => ({ granted: true }));
  safeHandle('tcc:requestAccess', async () => ({ granted: true }));

  // macOS dock — no-op on Linux
  safeHandle('dock:setBadge', async () => true);
  safeHandle('dock:bounce', async () => true);

  // Windows-specific
  safeHandle('windows:checkHyperV', async () => ({ available: true, enabled: true }));
  safeHandle('windows:enableHyperV', async () => true);
  safeHandle('windows:restartAfterVMPInstall', async () => true);

  // Auto-updater — handled by package manager on Linux
  safeHandle('autoUpdater:checkForUpdates', async () => ({
    available: false,
    message: 'Updates are managed by your package manager on Linux.',
  }));
  safeHandle('autoUpdater:downloadUpdate', async () => false);
  safeHandle('autoUpdater:installUpdate', async () => false);

  // Touch bar (macOS) — no-op
  safeHandle('touchBar:update', async () => true);

  console.log('[cowork-linux] Linux platform stubs registered');
}

/**
 * Safely register an IPC handler, skipping if already registered.
 */
function safeHandle(channel, handler) {
  try {
    ipcMain.handle(channel, handler);
  } catch (err) {
    // Handler already registered — that's fine
    if (!err.message.includes('already registered')) {
      console.error(`[cowork-linux] Failed to register ${channel}:`, err.message);
    }
  }
}

module.exports = { registerLinuxStubs };
