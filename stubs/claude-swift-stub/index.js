/**
 * Linux stub for @ant/claude-swift (or Windows cowork-svc equivalent).
 *
 * On macOS, this is a native Swift addon managing Apple's Virtualization Framework.
 * On Windows, this role is played by cowork-svc.exe over named pipes.
 * On Linux, we spawn Claude Code CLI directly with optional sandboxing
 * via bubblewrap when available, or directly on the host.
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
  path.join(os.homedir(), '.local', 'bin', 'claude'),
  path.join(os.homedir(), '.npm-global', 'bin', 'claude'),
  '/usr/local/bin/claude',
  '/usr/bin/claude',
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

// Default resource limits for sandboxed sessions (enforced via systemd-run).
// Users can override these in ~/.config/Claude/cowork-limits.json:
//   { "memoryMax": "8G", "cpuQuota": "400%", "tasksMax": "1024" }
const DEFAULT_RESOURCE_LIMITS = {
  memoryMax: '4G',
  cpuQuota: '200%',   // 2 full cores
  tasksMax: '512',     // prevent fork bombs
};

function loadResourceLimits() {
  const configPath = path.join(
    process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config'),
    'Claude', 'cowork-limits.json'
  );
  try {
    const raw = fs.readFileSync(configPath, 'utf8');
    const overrides = JSON.parse(raw);
    // Only accept known keys with valid formats to prevent injection
    const result = { ...DEFAULT_RESOURCE_LIMITS };
    if (typeof overrides.memoryMax === 'string' && /^\d+[GMKT]$/i.test(overrides.memoryMax)) {
      result.memoryMax = overrides.memoryMax;
    }
    if (typeof overrides.cpuQuota === 'string' && /^\d+%$/.test(overrides.cpuQuota)) {
      result.cpuQuota = overrides.cpuQuota;
    }
    if (typeof overrides.tasksMax === 'string' && /^\d+$/.test(overrides.tasksMax)) {
      result.tasksMax = overrides.tasksMax;
    }
    return result;
  } catch (_) {
    return DEFAULT_RESOURCE_LIMITS;
  }
}

const RESOURCE_LIMITS = loadResourceLimits();

// Maximum concurrent Cowork sessions (prevent resource exhaustion)
const MAX_CONCURRENT_SESSIONS = 10;

// Allowed binary path prefixes (prevent arbitrary command execution)
const BINARY_PATH_ALLOWLIST = [
  '/usr/lib64/claude-desktop-hardened/',
  '/usr/lib/claude-desktop-hardened/',
  '/usr/local/bin/',
  '/usr/bin/',
  path.join(os.homedir(), '.local', 'bin') + '/',
  path.join(os.homedir(), '.local', 'share', 'claude') + '/',
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
 *
 * process.env is filtered strictly (only ENV_ALLOWLIST).
 * extraEnv comes from the trusted Electron app session config and is
 * passed through entirely — it contains CLAUDE_CODE_BRIEF, TZ, etc.
 * that the CLI needs but that should not leak from the host env.
 */
function filterEnv(extraEnv = {}) {
  const filtered = {};
  for (const key of ENV_ALLOWLIST) {
    if (process.env[key] !== undefined) {
      filtered[key] = process.env[key];
    }
  }
  // Pass through all env vars from the Electron app session config.
  // These are set by the app itself (not user-controlled) and include
  // CLAUDE_CODE_BRIEF, CLAUDE_CODE_IS_COWORK, TZ, etc.
  for (const [key, value] of Object.entries(extraEnv)) {
    if (value !== undefined) {
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
  // Block path traversal — check raw input before normalize resolves it
  if (p.includes('..')) return false;
  const normalized = path.normalize(p);
  // Block access to sensitive directories and persistence vectors
  const sensitive = [
    '.ssh', '.gnupg', '.aws', '.kube', '.docker',
    '.bashrc', '.bash_profile', '.profile', '.zshrc',
    '.config/autostart', '.local/share/autostart',
    'cron', '.pam_environment',
  ];
  for (const dir of sensitive) {
    if (normalized.includes(`/${dir}/`) || normalized.endsWith(`/${dir}`) || normalized.endsWith(`/${dir}`)) {
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
 * Priority: bubblewrap > host
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

  // bubblewrap is a hard dependency — warn loudly if missing
  console.error('[cowork-linux] WARNING: bubblewrap not found! Cowork sessions will run unsandboxed.');
  console.error('[cowork-linux] Install bubblewrap: sudo dnf install bubblewrap / sudo apt install bubblewrap / sudo pacman -S bubblewrap');
  return 'host';
}

/** Check if systemd-run is available for resource limiting. */
function hasSystemdRun() {
  try {
    fs.accessSync('/usr/bin/systemd-run', fs.constants.X_OK);
    return true;
  } catch (_) {
    return false;
  }
}

/** Resolve full path to bwrap binary. */
function resolveBwrap() {
  for (const p of ['/usr/bin/bwrap', '/usr/local/bin/bwrap']) {
    try { fs.accessSync(p, fs.constants.X_OK); return p; } catch (_) {}
  }
  throw new Error('bubblewrap (bwrap) not found at /usr/bin/bwrap or /usr/local/bin/bwrap');
}

/**
 * Conditionally add a read-only bind mount if the path exists on the host.
 */
function roBindIfExists(bwrapArgs, hostPath, destPath) {
  try {
    fs.statSync(hostPath);
    bwrapArgs.push('--ro-bind', hostPath, destPath || hostPath);
  } catch (_) {}
}

/**
 * Build the command and args for bubblewrap sandboxing.
 *
 * Uses a default-deny filesystem policy: nothing is mounted unless
 * explicitly listed. This prevents the agent from reading browser data,
 * password managers, other users' files, or anything outside its workspace.
 */
function buildBwrapCommand(claudeBinary, args, workDir, env) {
  const home = os.homedir();
  const bwrapArgs = [
    '--die-with-parent',
    // NOTE: Do NOT use --unshare-net — Claude Code needs HTTPS to reach the Anthropic API
  ];

  // --- Minimal read-only rootfs (default-deny) ---
  // System binaries and libraries
  roBindIfExists(bwrapArgs, '/usr');
  roBindIfExists(bwrapArgs, '/lib');
  roBindIfExists(bwrapArgs, '/lib64');
  // /bin and /sbin may be symlinks to /usr/bin on merged-usr distros
  try {
    if (fs.lstatSync('/bin').isSymbolicLink()) {
      bwrapArgs.push('--symlink', 'usr/bin', '/bin');
    } else {
      roBindIfExists(bwrapArgs, '/bin');
    }
  } catch (_) { roBindIfExists(bwrapArgs, '/bin'); }
  try {
    if (fs.lstatSync('/sbin').isSymbolicLink()) {
      bwrapArgs.push('--symlink', 'usr/sbin', '/sbin');
    } else {
      roBindIfExists(bwrapArgs, '/sbin');
    }
  } catch (_) { roBindIfExists(bwrapArgs, '/sbin'); }

  // Selective /etc — only what node/networking needs
  const etcFiles = [
    '/etc/resolv.conf', '/etc/hosts', '/etc/nsswitch.conf',
    '/etc/passwd', '/etc/group', '/etc/localtime', '/etc/hostname',
    '/etc/ssl', '/etc/ca-certificates', '/etc/pki',
    '/etc/ld.so.cache', '/etc/ld.so.conf', '/etc/ld.so.conf.d',
  ];
  for (const f of etcFiles) {
    roBindIfExists(bwrapArgs, f);
  }

  // Virtual filesystems
  bwrapArgs.push('--dev', '/dev');
  bwrapArgs.push('--proc', '/proc');
  bwrapArgs.push('--tmpfs', '/tmp');

  // Block all of /home, then allow only what's needed
  bwrapArgs.push('--tmpfs', '/home');

  // Writable: workspace and session data
  bwrapArgs.push('--bind', workDir, workDir);
  bwrapArgs.push('--bind', SESSION_BASE, SESSION_BASE);

  // Writable: Claude-specific config dirs
  const writableDirs = [
    path.join(home, '.config', 'Claude'),
    path.join(home, '.claude'),
    path.join(home, '.local', 'share', 'claude'),
    path.join(home, '.local', 'state', 'claude'),
  ];
  for (const dir of writableDirs) {
    try {
      fs.mkdirSync(dir, { recursive: true });
      bwrapArgs.push('--bind', dir, dir);
    } catch (_) {}
  }

  // Read-only: Claude config file in home directory root
  roBindIfExists(bwrapArgs, path.join(home, '.claude.json'));

  // Read-only: Claude CLI binary installed via `claude update` (symlink target)
  roBindIfExists(bwrapArgs, path.join(home, '.local', 'share', 'claude'));
  // Read-only: user-local bin (contains claude symlink)
  roBindIfExists(bwrapArgs, path.join(home, '.local', 'bin'));

  // Read-only: node/npm paths the CLI may need to resolve modules
  const nodeReadonly = [
    path.join(home, '.nvm'),
    path.join(home, '.npm'),
    path.join(home, '.node_modules'),
  ];
  for (const dir of nodeReadonly) {
    roBindIfExists(bwrapArgs, dir);
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
    if (this._processes.size >= MAX_CONCURRENT_SESSIONS) {
      throw new Error(`Maximum concurrent sessions (${MAX_CONCURRENT_SESSIONS}) reached`);
    }

    const claudeBinary = this._getClaudeBinary();

    // args comes from the app as an array of CLI arguments
    const safeArgs = Array.isArray(args) ? args : [];

    // Translate VM paths in arguments
    const translatedArgs = safeArgs.map(arg => translatePath(arg));

    // Set up working directory
    const workDir = translatePath(cwd) || os.homedir();

    // Filter environment
    const filteredEnv = filterEnv(env || {});

    // Bypass system OpenSSL config that may enforce FIPS restrictions
    // (common on Fedora/RHEL) which prevent the Node.js CLI from starting.
    // The CLI itself handles its own TLS — it doesn't need the system FIPS policy.
    filteredEnv.OPENSSL_CONF = '/dev/null';

    // Translate VM paths in environment values
    for (const [key, value] of Object.entries(filteredEnv)) {
      if (typeof value === 'string' && key !== 'OPENSSL_CONF') {
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

      let spawnCmd, spawnArgs;
      if (hasSystemdRun()) {
        // Wrap with systemd-run for cgroup resource limits
        spawnCmd = '/usr/bin/systemd-run';
        spawnArgs = [
          '--scope', '--user', '--quiet',
          `--property=MemoryMax=${RESOURCE_LIMITS.memoryMax}`,
          `--property=CPUQuota=${RESOURCE_LIMITS.cpuQuota}`,
          `--property=TasksMax=${RESOURCE_LIMITS.tasksMax}`,
          '--', bwrapCmd, ...bwrapArgs,
        ];
        console.log(`[cowork-linux] Resource limits: mem=${RESOURCE_LIMITS.memoryMax} cpu=${RESOURCE_LIMITS.cpuQuota} tasks=${RESOURCE_LIMITS.tasksMax}`);
      } else {
        console.warn('[cowork-linux] systemd-run not available — no resource limits applied');
        spawnCmd = bwrapCmd;
        spawnArgs = bwrapArgs;
      }

      child = spawn(spawnCmd, spawnArgs, {
        cwd: workDir,
        env: bwrapEnv,
        stdio: ['pipe', 'pipe', 'pipe'],
      });
    } else {
      // Host backend — refuse to run unsandboxed
      throw new Error(
        'bubblewrap (bwrap) is required for Cowork sessions. ' +
        'Install it: sudo dnf install bubblewrap / sudo apt install bubblewrap / sudo pacman -S bubblewrap'
      );
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
    if (!isPathSafe(hostPath)) {
      console.error(`[cowork-linux] Mount blocked: unsafe path ${hostPath}`);
      return false;
    }

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
    if (!isPathSafe(hostPath)) {
      console.error(`[cowork-linux] openFile blocked: unsafe path ${hostPath}`);
      return;
    }
    execFile('xdg-open', [hostPath], (err) => {
      if (err) console.error(`[cowork-linux] xdg-open failed: ${err.message}`);
    });
  }

  /**
   * Reveal a file in the system file manager.
   */
  revealFile(filePath) {
    const hostPath = translatePath(filePath);
    if (!isPathSafe(hostPath)) {
      console.error(`[cowork-linux] revealFile blocked: unsafe path ${hostPath}`);
      return;
    }
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
   * Delegates to the Computer Use module for X11/Wayland auto-detection.
   */
  getOpenWindows() {
    try {
      const { getOpenWindows } = require('../cowork/computer_use');
      return getOpenWindows();
    } catch (err) {
      console.error(`[cowork-linux] getOpenWindows failed: ${err.message}`);
      return [];
    }
  }

  /**
   * Capture a screenshot via grim (Wayland) or scrot (X11).
   * Returns base64-encoded PNG.
   */
  captureScreenshot() {
    try {
      const { captureScreenshot } = require('../cowork/computer_use');
      return captureScreenshot();
    } catch (err) {
      console.error(`[cowork-linux] Screenshot failed: ${err.message}`);
      return null;
    }
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

  // .computerUse — native computer use interface (tcc, screenshot, display, apps)
  // On macOS this is a native Swift addon; on Linux we delegate to our
  // computer_use.js module which uses grim/xdotool/ydotool/wmctrl.
  computerUse: (() => {
    let cu;
    try { cu = require('../cowork/computer_use'); } catch (_) { cu = null; }
    let cuPerm;
    try { cuPerm = require('../cowork/computer_use_permission'); } catch (_) { cuPerm = null; }

    const { screen } = require('electron');

    // Get primary display info for display.getSize / listAll
    function getDisplayObj(d) {
      return {
        displayId: d.id,
        width: d.size.width,
        height: d.size.height,
        scaleFactor: d.scaleFactor,
        originX: d.bounds.x,
        originY: d.bounds.y,
        isPrimary: d.id === screen.getPrimaryDisplay().id,
        label: d.label || `Display ${d.id}`,
      };
    }

    return {
      tcc: {
        // On Linux there is no macOS TCC (Transparency, Consent, Control).
        // Always report granted so the computer-use MCP server doesn't
        // short-circuit with "macOS Accessibility/Screen Recording not granted".
        // Actual permissions are enforced by the sandbox and tool stubs.
        checkAccessibility() {
          return true;
        },
        checkScreenRecording() {
          return true;
        },
        requestAccessibility() {
          return { granted: true };
        },
        requestScreenRecording() {
          return { granted: true };
        },
      },

      screenshot: {
        captureExcluding(_allowedBundleIds, _quality, width, height, _displayId) {
          // Capture full screen, return as base64 PNG
          if (!cu) throw new Error('computer_use module not available');
          const b64 = cu.captureScreenshot();
          return { data: b64, width, height };
        },
        captureRegion(_scale, x, y, w, h, outW, outH, _quality, _displayId) {
          // Linux: capture full screen (region crop would require extra tooling)
          if (!cu) throw new Error('computer_use module not available');
          const b64 = cu.captureScreenshot();
          return { data: b64, x, y, w, h, width: outW, height: outH };
        },
      },

      display: {
        getSize(displayId) {
          const displays = screen.getAllDisplays();
          const d = displayId != null
            ? (displays.find(dd => dd.id === displayId) || screen.getPrimaryDisplay())
            : screen.getPrimaryDisplay();
          return {
            width: d.size.width,
            height: d.size.height,
            scaleFactor: d.scaleFactor,
          };
        },
        listAll() {
          return screen.getAllDisplays().map(getDisplayObj);
        },
      },

      apps: {
        prepareDisplay(_displayId, _bundleId, _hideSet) {
          return { activated: null, hidden: [] };
        },
        previewHideSet(_excludeBundleIds, _displayId) {
          return [];
        },
        findWindowDisplays(_bundleIds) {
          // Return primary display for all
          const primary = screen.getPrimaryDisplay();
          return [primary.id];
        },
        listInstalled() {
          // Return installed Linux desktop applications.
          // The permission system matches requested app names against this list
          // by bundleId (exact) or displayName (case-insensitive).
          const apps = [];
          const seen = new Set();
          const dataDirs = [
            '/usr/share/applications',
            '/usr/local/share/applications',
            path.join(os.homedir(), '.local', 'share', 'applications'),
          ];
          for (const dir of dataDirs) {
            let entries;
            try { entries = fs.readdirSync(dir); } catch (_) { continue; }
            for (const entry of entries) {
              if (!entry.endsWith('.desktop')) continue;
              const filePath = path.join(dir, entry);
              try {
                const content = fs.readFileSync(filePath, 'utf8');
                // Extract Name= and Exec= from [Desktop Entry]
                const nameMatch = content.match(/^Name=(.+)$/m);
                const execMatch = content.match(/^Exec=(\S+)/m);
                const noDisplay = content.match(/^NoDisplay=true$/m);
                if (!nameMatch || noDisplay) continue;
                const displayName = nameMatch[1].trim();
                const bundleId = entry.replace('.desktop', '');
                if (seen.has(bundleId)) continue;
                seen.add(bundleId);
                apps.push({
                  bundleId,
                  displayName,
                  path: execMatch ? execMatch[1] : '/usr/bin/' + bundleId,
                });
              } catch (_) {}
            }
          }
          return apps;
        },
        listRunning() {
          if (!cu) return [];
          try {
            return cu.getOpenWindows().map(w => ({
              bundleId: w.id,
              displayName: w.title,
            }));
          } catch (_) { return []; }
        },
        open(bundleId) {
          // Best effort: try xdg-open
          try {
            require('child_process').execFile('xdg-open', [bundleId]);
          } catch (_) {}
        },
        iconDataUrl(_bundleId) {
          return null;
        },
        appUnderPoint(_x, _y) {
          // Return the app under the given screen coordinates.
          // Used by the executor to validate click targets.
          if (!cu) return null;
          try {
            const windows = cu.getOpenWindows();
            if (windows.length > 0) {
              // Return the frontmost window as the "app under point".
              // On Linux we can't easily do hit-testing, but the first
              // window from the compositor is typically the focused one.
              const w = windows[0];
              return { bundleId: w.id, displayName: w.title };
            }
          } catch (_) {}
          return null;
        },
        unhide(_bundleIds) {},
      },

      resolvePrepareCapture(_allowedBundleIds, _hostBundleId, _quality, _w, _h, _displayId, _autoResolve, _doHide) {
        // No window hiding needed on Linux
        if (!cu) throw new Error('computer_use module not available');
        const b64 = cu.captureScreenshot();
        return { data: b64, hidden: [] };
      },
    };
  })(),
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
