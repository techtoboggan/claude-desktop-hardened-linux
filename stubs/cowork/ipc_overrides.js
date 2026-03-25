/**
 * IPC handler overrides for Cowork on Linux.
 *
 * Registers Electron ipcMain handlers that intercept Cowork-related
 * IPC channels and route them to our Linux-native session orchestrator
 * instead of the Windows cowork-svc or macOS Swift addon.
 *
 * All registrations use safeHandle() which removes any existing handler
 * before registering ours — this prevents "already registered" crashes
 * when our injected code races with the app's own handler registration.
 */

'use strict';

const { ipcMain } = require('electron');
const { SessionOrchestrator } = require('./session_orchestrator');
let swiftStub;
try {
  swiftStub = require('@ant/claude-swift');
} catch (_) {
  swiftStub = require('claude-swift-stub');
}

let orchestrator = null;

/**
 * Initialize the orchestrator (lazy, singleton).
 */
function getOrchestrator() {
  if (!orchestrator) {
    // swiftStub is module.exports which has .vm; pass the vm object to orchestrator
    const vm = swiftStub.vm || (swiftStub.default && swiftStub.default.vm) || swiftStub;
    orchestrator = new SessionOrchestrator(vm);
  }
  return orchestrator;
}

/**
 * Safely register an IPC handler, replacing any existing one.
 */
function safeHandle(channel, handler) {
  try {
    ipcMain.removeHandler(channel);
  } catch (_) {
    // No existing handler — that's fine
  }
  try {
    ipcMain.handle(channel, handler);
  } catch (err) {
    console.error(`[cowork-linux] Failed to register ${channel}:`, err.message);
  }
}

/**
 * Register all Cowork IPC handlers.
 * Call this during app startup, after the main window is created.
 */
function registerCoworkHandlers() {
  const orch = getOrchestrator();

  // --- LocalAgentModeSessions ---

  safeHandle('localAgentModeSessions:start', async (_event, options) => {
    return orch.start(options);
  });

  safeHandle('localAgentModeSessions:stop', async (_event, sessionId) => {
    return orch.stop(sessionId);
  });

  safeHandle('localAgentModeSessions:sendMessage', async (_event, sessionId, message) => {
    return orch.sendMessage(sessionId, message);
  });

  safeHandle('localAgentModeSessions:archive', async (_event, sessionId) => {
    return orch.archive(sessionId);
  });

  safeHandle('localAgentModeSessions:list', async () => {
    return orch.listSessions();
  });

  safeHandle('localAgentModeSessions:get', async (_event, sessionId) => {
    return orch.getSession(sessionId);
  });

  safeHandle('localAgentModeSessions:resume', async (_event, sessionId, options) => {
    return orch.resume(sessionId, options);
  });

  safeHandle('localAgentModeSessions:setChromePermissionMode', async (_event, _mode) => {
    // No-op on Linux — no Chrome permission sandboxing
    return true;
  });

  safeHandle('localAgentModeSessions:deleteBridgeAgentMemory', async () => {
    // Clear shared memory file if it exists
    return true;
  });

  safeHandle('localAgentModeSessions:abandonBridgeEnvironment', async (_event, sessionId) => {
    return orch.stop(sessionId);
  });

  safeHandle('localAgentModeSessions:requestFolderTccAccess', async (_event, _path) => {
    // No TCC on Linux — always granted
    return { granted: true };
  });

  // --- ClaudeVM ---
  // Access methods via .vm (the module export shape changed to { vm: {...}, desktop: {...} })
  const vm = swiftStub.vm || swiftStub;

  safeHandle('claudeVM:download', async () => {
    return vm.download();
  });

  safeHandle('claudeVM:getDownloadStatus', async () => {
    return vm.getDownloadStatus();
  });

  safeHandle('claudeVM:startVM', async () => {
    return vm.startVM();
  });

  safeHandle('claudeVM:stopVM', async () => {
    return vm.stopVM();
  });

  safeHandle('claudeVM:setYukonSilverConfig', async (_event, config) => {
    return vm.setYukonSilverConfig(config);
  });

  safeHandle('claudeVM:deleteAndReinstall', async () => {
    return vm.deleteAndReinstall();
  });

  safeHandle('claudeVM:checkVirtualMachinePlatform', async () => {
    return vm.checkVirtualMachinePlatform();
  });

  safeHandle('claudeVM:enableVirtualMachinePlatform', async () => {
    return vm.enableVirtualMachinePlatform();
  });

  // --- AppFeatures ---

  safeHandle('appFeatures:getSupportedFeatures', async () => {
    return {
      cowork: true,
      localAgentMode: true,
      coworkScheduledTasks: true,
      coworkMemory: true,
      coworkSpaces: true,
    };
  });

  // --- CoworkScheduledTasks ---

  safeHandle('coworkScheduledTasks:list', async () => {
    return [];  // TODO: Implement scheduled tasks
  });

  safeHandle('coworkScheduledTasks:create', async (_event, _task) => {
    return { id: 'stub', status: 'pending' };
  });

  safeHandle('coworkScheduledTasks:update', async (_event, _taskId, _updates) => {
    return true;
  });

  safeHandle('coworkScheduledTasks:delete', async (_event, _taskId) => {
    return true;
  });

  // --- CoworkMemory ---

  safeHandle('coworkMemory:readGlobalMemory', async () => {
    return {};
  });

  safeHandle('coworkMemory:writeGlobalMemory', async (_event, _data) => {
    return true;
  });

  // --- CoworkSpaces ---

  safeHandle('coworkSpaces:list', async () => {
    return [];
  });

  safeHandle('coworkSpaces:create', async (_event, _space) => {
    return { id: 'stub', status: 'created' };
  });

  console.log('[cowork-linux] IPC handlers registered');
}

/**
 * Unregister all Cowork IPC handlers (for cleanup).
 */
function unregisterCoworkHandlers() {
  const channels = [
    'localAgentModeSessions:start',
    'localAgentModeSessions:stop',
    'localAgentModeSessions:sendMessage',
    'localAgentModeSessions:archive',
    'localAgentModeSessions:list',
    'localAgentModeSessions:get',
    'localAgentModeSessions:resume',
    'localAgentModeSessions:setChromePermissionMode',
    'localAgentModeSessions:deleteBridgeAgentMemory',
    'localAgentModeSessions:abandonBridgeEnvironment',
    'localAgentModeSessions:requestFolderTccAccess',
    'claudeVM:download',
    'claudeVM:getDownloadStatus',
    'claudeVM:startVM',
    'claudeVM:stopVM',
    'claudeVM:setYukonSilverConfig',
    'claudeVM:deleteAndReinstall',
    'claudeVM:checkVirtualMachinePlatform',
    'claudeVM:enableVirtualMachinePlatform',
    'appFeatures:getSupportedFeatures',
    'coworkScheduledTasks:list',
    'coworkScheduledTasks:create',
    'coworkScheduledTasks:update',
    'coworkScheduledTasks:delete',
    'coworkMemory:readGlobalMemory',
    'coworkMemory:writeGlobalMemory',
    'coworkSpaces:list',
    'coworkSpaces:create',
  ];

  for (const channel of channels) {
    try {
      ipcMain.removeHandler(channel);
    } catch (_) {}
  }
}

/**
 * Graceful shutdown.
 */
async function shutdown() {
  if (orchestrator) {
    await orchestrator.shutdown();
  }
}

module.exports = {
  registerCoworkHandlers,
  unregisterCoworkHandlers,
  shutdown,
  getOrchestrator,
};
