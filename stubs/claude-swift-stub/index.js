/**
 * Linux stub for @ant/claude-swift (or Windows cowork-svc equivalent).
 *
 * On macOS, this is a native Swift addon managing Apple's Virtualization Framework.
 * On Windows, this role is played by cowork-svc.exe over named pipes.
 * On Linux, we spawn Claude Code CLI directly with optional sandboxing
 * via bubblewrap or KVM/QEMU.
 *
 * This stub implements the same interface so the Electron app's IPC handlers
 * work without modification.
 */

'use strict';

const { execFile, spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const SESSION_BASE = path.join(
  process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config'),
  'Claude',
  'local-agent-mode-sessions'
);

const CLAUDE_BINARY_SEARCH_PATHS = [
  '/usr/bin/claude',
  '/usr/local/bin/claude',
  path.join(os.homedir(), '.local', 'bin', 'claude'),
  path.join(os.homedir(), '.npm-global', 'bin', 'claude'),
];

// Environment variables allowed to pass through to Claude Code CLI
const ENV_ALLOWLIST = new Set([
  'HOME', 'USER', 'LOGNAME', 'SHELL', 'PATH', 'LANG', 'LC_ALL',
  'TERM', 'DISPLAY', 'WAYLAND_DISPLAY', 'XDG_RUNTIME_DIR',
  'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME', 'XDG_CACHE_HOME',
  'XDG_SESSION_TYPE', 'DBUS_SESSION_BUS_ADDRESS',
  'CLAUDE_CODE_OAUTH_TOKEN',
  'NODE_ENV', 'ELECTRON_RUN_AS_NODE',
  'SSH_AUTH_SOCK',
]);

// Allowed binary path prefixes (prevent arbitrary command execution)
const BINARY_PATH_ALLOWLIST = [
  '/usr/lib64/claude-desktop/',
  '/usr/lib/claude-desktop/',
  '/usr/local/bin/',
  '/usr/bin/',
  path.join(os.homedir(), '.local', 'bin') + '/',
  path.join(os.homedir(), '.npm-global', 'bin') + '/',
  path.join(os.homedir(), '.config', 'Claude', 'claude-code-vm') + '/',
];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Resolve the Claude Code CLI binary path.
 * Checks known paths, then falls back to PATH lookup.
 */
function resolveClaudeBinary() {
  for (const p of CLAUDE_BINARY_SEARCH_PATHS) {
    try {
      fs.accessSync(p, fs.constants.X_OK);
      return p;
    } catch (_) {
      // not found, continue
    }
  }

  // Try version managers: mise, asdf
  const versionManagerPaths = [
    path.join(os.homedir(), '.local', 'share', 'mise', 'shims', 'claude'),
    path.join(os.homedir(), '.asdf', 'shims', 'claude'),
  ];
  for (const p of versionManagerPaths) {
    try {
      fs.accessSync(p, fs.constants.X_OK);
      return p;
    } catch (_) {
      // continue
    }
  }

  // Last resort: check PATH
  const { execFileSync } = require('child_process');
  try {
    const result = execFileSync('which', ['claude'], { encoding: 'utf8' }).trim();
    if (result) return result;
  } catch (_) {
    // not found
  }

  return null;
}

/**
 * Validate that a binary path is within allowed prefixes.
 */
function isPathAllowed(binaryPath) {
  const resolved = fs.realpathSync(binaryPath);
  return BINARY_PATH_ALLOWLIST.some(prefix => resolved.startsWith(prefix));
}

/**
 * Filter environment variables through the allowlist.
 */
function filterEnv(extraEnv = {}) {
  const filtered = {};
  for (const key of ENV_ALLOWLIST) {
    if (process.env[key] !== undefined) {
      filtered[key] = process.env[key];
    }
  }
  // Merge extra env (e.g., CLAUDE_CODE_OAUTH_TOKEN from the app)
  for (const [key, value] of Object.entries(extraEnv)) {
    if (ENV_ALLOWLIST.has(key)) {
      filtered[key] = value;
    }
  }
  return filtered;
}

/**
 * Translate VM-style paths to host paths.
 * On macOS/Windows, the VM has paths like /sessions/<name>/mnt/...
 * We translate those to the host session directory.
 */
function translatePath(vmPath) {
  if (!vmPath || typeof vmPath !== 'string') return vmPath;

  // /sessions/<name>/mnt/<rest> → ~/.config/Claude/local-agent-mode-sessions/sessions/<name>/mnt/<rest>
  const vmSessionMatch = vmPath.match(/^\/sessions\/([^/]+)\/mnt\/(.*)$/);
  if (vmSessionMatch) {
    const [, sessionName, rest] = vmSessionMatch;
    return path.join(SESSION_BASE, 'sessions', sessionName, 'mnt', rest);
  }

  // /sessions/<name> (no /mnt/) — map to session base dir
  const vmSessionBase = vmPath.match(/^\/sessions\/([^/]+)(\/.*)?$/);
  if (vmSessionBase) {
    const [, sessionName, rest] = vmSessionBase;
    const translated = path.join(SESSION_BASE, 'sessions', sessionName, rest || '');
    // Ensure directory exists
    try { fs.mkdirSync(translated, { recursive: true }); } catch (_) {}
    return translated;
  }

  // /home/user/... paths pass through unchanged
  return vmPath;
}

/**
 * Check path safety — no directory traversal.
 */
function isPathSafe(p) {
  if (!p || typeof p !== 'string') return false;
  const normalized = path.normalize(p);
  // Block path traversal
  if (normalized.includes('..')) return false;
  // Block access to sensitive directories
  const sensitive = ['.ssh', '.gnupg', '.aws', '.kube'];
  for (const dir of sensitive) {
    if (normalized.includes(`/${dir}/`) || normalized.endsWith(`/${dir}`)) {
      return false;
    }
  }
  return true;
}

// ---------------------------------------------------------------------------
// Sandbox backends
// ---------------------------------------------------------------------------

/**
 * Detect best available sandbox backend.
 * Priority: bubblewrap > host (KVM support can be added later)
 */
function detectBackend() {
  // Check for bubblewrap at known paths (don't rely on PATH in Electron)
  const bwrapPaths = ['/usr/bin/bwrap', '/usr/local/bin/bwrap'];
  for (const p of bwrapPaths) {
    try {
      fs.accessSync(p, fs.constants.X_OK);
      return 'bubblewrap';
    } catch (_) {}
  }

  return 'host';
}

/** Resolve full path to bwrap binary. */
function resolveBwrap() {
  for (const p of ['/usr/bin/bwrap', '/usr/local/bin/bwrap']) {
    try { fs.accessSync(p, fs.constants.X_OK); return p; } catch (_) {}
  }
  return 'bwrap'; // fallback to PATH
}

/**
 * Build the command and args for bubblewrap sandboxing.
 */
function buildBwrapCommand(claudeBinary, args, workDir, env) {
  const bwrapArgs = [
    '--ro-bind', '/', '/',              // Read-only root
    '--dev', '/dev',
    '--proc', '/proc',
    '--tmpfs', '/tmp',
    '--bind', workDir, workDir,         // Writable working directory
    '--bind', SESSION_BASE, SESSION_BASE, // Writable sessions dir
    // NOTE: Do NOT use --unshare-net — Claude Code needs HTTPS to reach the Anthropic API
    '--die-with-parent',
  ];

  // Allow write to config dirs Claude Code needs
  const writableDirs = [
    path.join(os.homedir(), '.config', 'Claude'),
    path.join(os.homedir(), '.claude'),
    path.join(os.homedir(), '.local', 'share'),
  ];
  for (const dir of writableDirs) {
    if (fs.existsSync(dir)) {
      bwrapArgs.push('--bind', dir, dir);
    }
  }

  // Block sensitive directories
  const sensitive = ['.ssh', '.gnupg', '.aws', '.kube'];
  for (const dir of sensitive) {
    const fullPath = path.join(os.homedir(), dir);
    if (fs.existsSync(fullPath)) {
      bwrapArgs.push('--tmpfs', fullPath);
    }
  }

  bwrapArgs.push('--', claudeBinary, ...args);

  return { command: resolveBwrap(), args: bwrapArgs, env };
}

// ---------------------------------------------------------------------------
// SwiftAddonStub — main exported class
// ---------------------------------------------------------------------------

class SwiftAddonStub {
  constructor() {
    this._processes = new Map();  // sessionId → child process
    this._eventCallbacks = {};    // registered via setEventCallbacks
    this._stdinHistory = new Map();
    this._backend = detectBackend();
    this._claudeBinary = null;

    console.log(`[cowork-linux] Sandbox backend: ${this._backend}`);
  }

  /**
   * Resolve and cache the Claude Code binary path.
   */
  _getClaudeBinary() {
    if (!this._claudeBinary) {
      this._claudeBinary = resolveClaudeBinary();
      if (!this._claudeBinary) {
        throw new Error(
          'Claude Code CLI not found. Install it via: npm install -g @anthropic-ai/claude-code\n' +
          'Or ensure it is available at one of: ' + CLAUDE_BINARY_SEARCH_PATHS.join(', ')
        );
      }
      if (!isPathAllowed(this._claudeBinary)) {
        throw new Error(`Claude binary path not in allowlist: ${this._claudeBinary}`);
      }
      console.log(`[cowork-linux] Using Claude binary: ${this._claudeBinary}`);
    }
    return this._claudeBinary;
  }

  /**
   * Spawn a Claude Code process.
   *
   * The app calls:
   *   vm.spawn(sessionId, processName, command, args, cwd, env,
   *            additionalMounts, isResume, allowedDomains, sharedCwdPath, oneShot)
   */
  spawn(sessionId, processName, command, args = [], cwd, env = {},
        additionalMounts, isResume, allowedDomains, sharedCwdPath, oneShot) {
    const claudeBinary = this._getClaudeBinary();

    // args comes from the app as an array of CLI arguments
    const safeArgs = Array.isArray(args) ? args : [];

    // Translate VM paths in arguments
    const translatedArgs = safeArgs.map(arg => translatePath(arg));

    // Set up working directory
    const workDir = translatePath(cwd) || os.homedir();

    // Filter environment
    const filteredEnv = filterEnv(env || {});

    // Translate VM paths in environment values
    for (const [key, value] of Object.entries(filteredEnv)) {
      if (typeof value === 'string') {
        filteredEnv[key] = translatePath(value);
      }
    }

    // Ensure session directory exists
    const sessionDir = path.join(SESSION_BASE, 'sessions', sessionId);
    fs.mkdirSync(path.join(sessionDir, 'mnt'), { recursive: true });

    let child;

    if (this._backend === 'bubblewrap') {
      const { command: bwrapCmd, args: bwrapArgs, env: bwrapEnv } =
        buildBwrapCommand(claudeBinary, translatedArgs, workDir, filteredEnv);
      child = spawn(bwrapCmd, bwrapArgs, {
        cwd: workDir,
        env: bwrapEnv,
        stdio: ['pipe', 'pipe', 'pipe'],
      });
    } else {
      // Host backend — direct execution
      child = spawn(claudeBinary, translatedArgs, {
        cwd: workDir,
        env: filteredEnv,
        stdio: ['pipe', 'pipe', 'pipe'],
      });
    }

    this._processes.set(sessionId, child);
    this._stdinHistory.set(sessionId, []);

    const cbs = this._eventCallbacks || {};

    if (cbs.onStdout) {
      child.stdout.on('data', data => cbs.onStdout(sessionId, data.toString()));
    }
    if (cbs.onStderr) {
      child.stderr.on('data', data => cbs.onStderr(sessionId, data.toString()));
    }

    child.on('exit', (code, signal) => {
      this._processes.delete(sessionId);
      this._stdinHistory.delete(sessionId);
      if (cbs.onExit) {
        cbs.onExit(sessionId, code, signal, 'exit');
      }
    });

    child.on('error', (err) => {
      console.error(`[cowork-linux] Process error for session ${sessionId}:`, err.message);
      this._processes.delete(sessionId);
      if (cbs.onError) {
        cbs.onError(sessionId, err.message, err.stack);
      }
    });

    return {
      pid: child.pid,
      sessionId,
      write: (data) => {
        if (child.stdin && !child.stdin.destroyed) {
          child.stdin.write(data);
          this._stdinHistory.get(sessionId)?.push(data);
        }
      },
      kill: (signal = 'SIGTERM') => {
        child.kill(signal);
      },
    };
  }

  /**
   * Kill a running session process.
   */
  kill(sessionId, signal = 'SIGTERM') {
    const proc = this._processes.get(sessionId);
    if (proc) {
      proc.kill(signal);
      this._processes.delete(sessionId);
      this._stdinHistory.delete(sessionId);
    }
    // App expects kill() to return a Promise (calls .catch() on it)
    return Promise.resolve(true);
  }

  /**
   * Write to a session's stdin.
   */
  writeStdin(sessionId, data) {
    const proc = this._processes.get(sessionId);
    if (proc && proc.stdin && !proc.stdin.destroyed) {
      proc.stdin.write(data);
      this._stdinHistory.get(sessionId)?.push(data);
    }
    // App expects a Promise (calls .catch() on it)
    return Promise.resolve(true);
  }

  /**
   * Read a file from the session's filesystem.
   */
  readFile(filePath) {
    const hostPath = translatePath(filePath);
    if (!isPathSafe(hostPath)) {
      throw new Error(`Path not allowed: ${filePath}`);
    }
    try {
      const content = fs.readFileSync(hostPath);
      return content.toString('base64');
    } catch (err) {
      throw new Error(`Failed to read file: ${err.message}`);
    }
  }

  /**
   * Write a file to the session's filesystem.
   */
  writeFile(filePath, base64Content) {
    const hostPath = translatePath(filePath);
    if (!isPathSafe(hostPath)) {
      throw new Error(`Path not allowed: ${filePath}`);
    }
    try {
      const dir = path.dirname(hostPath);
      fs.mkdirSync(dir, { recursive: true });
      fs.writeFileSync(hostPath, Buffer.from(base64Content, 'base64'));
      return true;
    } catch (err) {
      throw new Error(`Failed to write file: ${err.message}`);
    }
  }

  /**
   * Mount a host path into the session (create symlink).
   */
  mountPath(sessionId, hostPath, mountPoint) {
    const sessionDir = path.join(SESSION_BASE, 'sessions', sessionId, 'mnt');
    const linkPath = path.join(sessionDir, path.basename(mountPoint || hostPath));

    try {
      fs.mkdirSync(sessionDir, { recursive: true });
      // Remove existing symlink if present
      try { fs.unlinkSync(linkPath); } catch (_) {}
      fs.symlinkSync(hostPath, linkPath);
      return true;
    } catch (err) {
      console.error(`[cowork-linux] Mount failed: ${err.message}`);
      return false;
    }
  }

  /**
   * Open a file using the system's default application.
   */
  openFile(filePath) {
    const hostPath = translatePath(filePath);
    execFile('xdg-open', [hostPath], (err) => {
      if (err) console.error(`[cowork-linux] xdg-open failed: ${err.message}`);
    });
  }

  /**
   * Reveal a file in the system file manager.
   */
  revealFile(filePath) {
    const hostPath = translatePath(filePath);
    const dir = path.dirname(hostPath);

    // Try nautilus first, then generic xdg-open on directory
    execFile('nautilus', ['--select', hostPath], (err) => {
      if (err) {
        execFile('xdg-open', [dir], (err2) => {
          if (err2) console.error(`[cowork-linux] File reveal failed: ${err2.message}`);
        });
      }
    });
  }

  /**
   * Get list of open windows (for computer use).
   */
  getOpenWindows() {
    try {
      const { execFileSync } = require('child_process');
      const output = execFileSync('wmctrl', ['-l'], { encoding: 'utf8' });
      return output.split('\n').filter(Boolean).map(line => {
        const parts = line.split(/\s+/);
        return {
          id: parts[0],
          desktop: parts[1],
          title: parts.slice(3).join(' '),
        };
      });
    } catch (_) {
      return [];
    }
  }

  /**
   * Capture a screenshot (placeholder — requires further implementation).
   */
  captureScreenshot() {
    // TODO: Implement via grim (Wayland) or scrot/import (X11)
    console.warn('[cowork-linux] Screenshot capture not yet implemented');
    return null;
  }

  /**
   * OAuth token handling — pass-through, no storage in stub.
   */
  addApprovedOauthToken(_token) {
    // No-op: tokens are passed via environment variable CLAUDE_CODE_OAUTH_TOKEN
    return Promise.resolve(true);
  }

  /**
   * Check if a session process is running.
   */
  isRunning(sessionId) {
    return this._processes.has(sessionId);
  }

  /**
   * Check if the "VM guest" is connected (always true on Linux — no VM).
   */
  isGuestConnected() {
    return true;
  }

  /**
   * Install SDK in session (no-op on Linux — CLI is already native).
   */
  installSdk(_version) {
    return Promise.resolve(true);
  }

  // -------------------------------------------------------------------------
  // VM lifecycle stubs (no actual VM on Linux)
  // -------------------------------------------------------------------------

  startVM() {
    console.log('[cowork-linux] VM start requested (no-op on Linux — running natively)');
    return Promise.resolve(true);
  }

  stopVM() {
    // Kill all running session processes
    for (const [sessionId, proc] of this._processes) {
      proc.kill('SIGTERM');
      this._processes.delete(sessionId);
    }
    return Promise.resolve(true);
  }

  download() {
    // No VM image to download on Linux
    return Promise.resolve(true);
  }

  getDownloadStatus() {
    return { status: 'complete', progress: 100 };
  }

  deleteAndReinstall() {
    return Promise.resolve(true);
  }

  checkVirtualMachinePlatform() {
    // Linux always has the capability (KVM or direct execution)
    return Promise.resolve({ available: true, enabled: true });
  }

  enableVirtualMachinePlatform() {
    return Promise.resolve(true);
  }

  /**
   * Configure VM settings (YukonSilver config).
   */
  setYukonSilverConfig(_config) {
    // Store config but don't act on it — no VM to configure
    return true;
  }

  /**
   * Get the sandbox backend being used.
   */
  getBackend() {
    return this._backend;
  }

  /**
   * List directory contents.
   */
  listDirectory(dirPath) {
    const hostPath = translatePath(dirPath);
    if (!isPathSafe(hostPath)) {
      throw new Error(`Path not allowed: ${dirPath}`);
    }
    try {
      const entries = fs.readdirSync(hostPath, { withFileTypes: true });
      return entries.map(e => ({
        name: e.name,
        isDirectory: e.isDirectory(),
        isFile: e.isFile(),
        isSymlink: e.isSymbolicLink(),
      }));
    } catch (err) {
      throw new Error(`Failed to list directory: ${err.message}`);
    }
  }
}

// ---------------------------------------------------------------------------
// Exports
// ---------------------------------------------------------------------------

const stubInstance = new SwiftAddonStub();

/**
 * Wrap a function so its return value is always a Promise.
 * The app's eipc framework calls .catch() on every method result.
 */
function promisify(fn) {
  return function (...args) {
    try {
      const result = fn.apply(this, args);
      return result instanceof Promise ? result : Promise.resolve(result);
    } catch (err) {
      return Promise.reject(err);
    }
  };
}

// ---------------------------------------------------------------------------
// Module shape expected by Claude Desktop
//
// The app loads this module via:
//   const mod = (await import("@ant/claude-swift")).default
//
// It then accesses:
//   mod.vm   — VM/session lifecycle (spawn, kill, writeStdin, startVM, etc.)
//   mod.desktop — desktop integration (getOpenWindows, captureScreenshot, etc.)
//
// The eipc framework (typed IPC) calls into these objects from the main process.
// ---------------------------------------------------------------------------

const moduleExport = {
  // .vm — the primary interface used by bi() and all session/VM handlers.
  // All methods are promisified because the eipc framework calls .catch() on results.
  vm: {
    spawn: promisify(stubInstance.spawn.bind(stubInstance)),
    kill: promisify(stubInstance.kill.bind(stubInstance)),
    writeStdin: promisify(stubInstance.writeStdin.bind(stubInstance)),
    readFile: promisify(stubInstance.readFile.bind(stubInstance)),
    writeFile: promisify(stubInstance.writeFile.bind(stubInstance)),
    mountPath: promisify(stubInstance.mountPath.bind(stubInstance)),
    openFile: promisify(stubInstance.openFile.bind(stubInstance)),
    revealFile: promisify(stubInstance.revealFile.bind(stubInstance)),
    listDirectory: promisify(stubInstance.listDirectory.bind(stubInstance)),
    startVM: promisify(stubInstance.startVM.bind(stubInstance)),
    stopVM: promisify(stubInstance.stopVM.bind(stubInstance)),
    download: promisify(stubInstance.download.bind(stubInstance)),
    getDownloadStatus: promisify(stubInstance.getDownloadStatus.bind(stubInstance)),
    isRunning: promisify(stubInstance.isRunning.bind(stubInstance)),
    isProcessRunning: promisify(function(sessionId) {
      const running = stubInstance._processes.has(sessionId);
      return { running, exitCode: running ? undefined : 0 };
    }),
    isGuestConnected: promisify(stubInstance.isGuestConnected.bind(stubInstance)),
    checkVirtualMachinePlatform: promisify(stubInstance.checkVirtualMachinePlatform.bind(stubInstance)),
    enableVirtualMachinePlatform: promisify(stubInstance.enableVirtualMachinePlatform.bind(stubInstance)),
    addApprovedOauthToken: promisify(stubInstance.addApprovedOauthToken.bind(stubInstance)),
    setYukonSilverConfig: promisify(stubInstance.setYukonSilverConfig.bind(stubInstance)),
    installSdk: promisify(stubInstance.installSdk.bind(stubInstance)),
    // Event callbacks — synchronous, NOT promisified (called once at init, not via eipc)
    setEventCallbacks(onStdout, onStderr, onExit, onError, onNetworkStatus, onApiReachability, onStartupStep) {
      stubInstance._eventCallbacks = { onStdout, onStderr, onExit, onError, onNetworkStatus, onApiReachability, onStartupStep };
    },
    // Stubs for debug/dev features
    isDebugLoggingEnabled() { return false; },
    setDebugLogging(_enabled) {},
    showDebugWindow() { return Promise.resolve(); },
    hideDebugWindow() { return Promise.resolve(); },
    // VM lifecycle (no-ops on Linux — direct execution)
    deleteAndReinstall: promisify(stubInstance.deleteAndReinstall.bind(stubInstance)),
    configure() { return Promise.resolve(); },
    createVM() { return Promise.resolve(); },
  },

  // .desktop — desktop integration for computer use features
  desktop: {
    getOpenWindows: stubInstance.getOpenWindows.bind(stubInstance),
    captureScreenshot: stubInstance.captureScreenshot.bind(stubInstance),
    getOpenDocuments() { return []; },
  },
};

// When the app does `(await import("@ant/claude-swift")).default`, ESM-from-CJS
// wrapping makes `.default` === `module.exports`. So module.exports itself must
// have `.vm` and `.desktop` at the top level.
//
// When cowork stubs do `require("@ant/claude-swift")`, they also get module.exports
// directly, so `.default`, `.spawn`, etc. remain accessible for those consumers.

module.exports = moduleExport;

// Also attach flat convenience exports for require() consumers (cowork stubs)
module.exports.SwiftAddonStub = SwiftAddonStub;
module.exports.default = moduleExport;
module.exports.spawn = stubInstance.spawn.bind(stubInstance);
module.exports.kill = stubInstance.kill.bind(stubInstance);
module.exports.writeStdin = stubInstance.writeStdin.bind(stubInstance);
module.exports.readFile = stubInstance.readFile.bind(stubInstance);
module.exports.writeFile = stubInstance.writeFile.bind(stubInstance);
module.exports.mountPath = stubInstance.mountPath.bind(stubInstance);
module.exports.openFile = stubInstance.openFile.bind(stubInstance);
module.exports.revealFile = stubInstance.revealFile.bind(stubInstance);
module.exports.startVM = stubInstance.startVM.bind(stubInstance);
module.exports.stopVM = stubInstance.stopVM.bind(stubInstance);
module.exports.download = stubInstance.download.bind(stubInstance);
module.exports.getDownloadStatus = stubInstance.getDownloadStatus.bind(stubInstance);
module.exports.isRunning = stubInstance.isRunning.bind(stubInstance);
module.exports.isGuestConnected = stubInstance.isGuestConnected.bind(stubInstance);
module.exports.checkVirtualMachinePlatform = stubInstance.checkVirtualMachinePlatform.bind(stubInstance);
module.exports.addApprovedOauthToken = stubInstance.addApprovedOauthToken.bind(stubInstance);
module.exports.setYukonSilverConfig = stubInstance.setYukonSilverConfig.bind(stubInstance);
module.exports.getBackend = stubInstance.getBackend.bind(stubInstance);
