/**
 * Cowork for Linux — main entry point.
 *
 * This module wires together all Cowork components and provides
 * a single initialization function to be called during app startup.
 */

'use strict';

const { registerCoworkHandlers, shutdown } = require('./ipc_overrides');
const { registerLinuxStubs } = require('./linux_ipc_stubs');
const { ensureDirectories } = require('./dirs');
const { TranscriptStore } = require('./transcript_store');
const { FileWatchManager } = require('./file_watch_manager');

let initialized = false;
let transcriptStore = null;
let fileWatchManager = null;

/**
 * Initialize Cowork for Linux.
 * Call this once during Electron app startup (in main process, after app.ready).
 */
function initializeCowork() {
  if (initialized) {
    console.warn('[cowork-linux] Already initialized');
    return;
  }

  console.log('[cowork-linux] Initializing Cowork for Linux...');

  // Ensure XDG directories exist
  ensureDirectories();

  // Register IPC handlers
  registerCoworkHandlers();
  registerLinuxStubs();

  // Initialize transcript store
  transcriptStore = new TranscriptStore();

  // Initialize file watch manager
  fileWatchManager = new FileWatchManager();

  // Log detected display server for Computer Use
  try {
    const { detectDisplayServer } = require('./computer_use');
    console.log(`[cowork-linux] Display server: ${detectDisplayServer()}`);
  } catch (_) {}

  initialized = true;
  console.log('[cowork-linux] Cowork initialized successfully');
}

/**
 * Graceful shutdown — call this on app quit.
 */
async function shutdownCowork() {
  if (!initialized) return;

  console.log('[cowork-linux] Shutting down...');

  // Flush transcripts
  if (transcriptStore) {
    transcriptStore.flushAll();
  }

  // Stop file watchers
  if (fileWatchManager) {
    fileWatchManager.unwatchAll();
  }

  // Stop all sessions
  await shutdown();

  initialized = false;
}

module.exports = {
  initializeCowork,
  shutdownCowork,
  getTranscriptStore: () => transcriptStore,
  getFileWatchManager: () => fileWatchManager,
};
