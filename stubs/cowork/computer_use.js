/**
 * Computer Use tool dispatcher for Linux.
 *
 * Auto-detects X11 vs Wayland and delegates to the appropriate tools.
 * All actions are logged to the transcript store with credential redaction.
 *
 * Tools run on the host (outside bubblewrap) since they need display
 * server access. Access is gated by computer_use_permission.js.
 */

'use strict';

const { execFileSync } = require('child_process');
const fs = require('fs');
const { redactForLogs } = require('./credential_classifier');

// Only search known system paths — no arbitrary PATH traversal
const TOOL_SEARCH_PATHS = ['/usr/bin/', '/usr/local/bin/'];

/**
 * Detect the active display server.
 */
function detectDisplayServer() {
  if (process.env.CLAUDE_DISPLAY_SERVER) {
    return process.env.CLAUDE_DISPLAY_SERVER;
  }
  if (process.env.WAYLAND_DISPLAY || process.env.XDG_SESSION_TYPE === 'wayland') {
    return 'wayland';
  }
  if (process.env.DISPLAY) {
    return 'x11';
  }
  return 'headless';
}

/**
 * Find a tool binary in known system paths only.
 */
function findTool(name) {
  for (const prefix of TOOL_SEARCH_PATHS) {
    const p = prefix + name;
    try {
      fs.accessSync(p, fs.constants.X_OK);
      return p;
    } catch (_) {}
  }
  return null;
}

/**
 * Log a Computer Use action to the transcript store.
 */
function logAction(action, details) {
  try {
    const { getTranscriptStore } = require('./index');
    const store = getTranscriptStore();
    if (store) {
      store.append('system', 'computer_use', redactForLogs(`${action}: ${JSON.stringify(details)}`));
    }
  } catch (_) {
    // Transcript store may not be initialized yet
  }
}

// ---------------------------------------------------------------------------
// Screenshot
// ---------------------------------------------------------------------------

function captureScreenshotWayland() {
  const grim = findTool('grim');
  if (!grim) throw new Error('grim not found — install grim for Wayland screenshots');
  const buffer = execFileSync(grim, ['-'], { maxBuffer: 50 * 1024 * 1024 });
  return buffer.toString('base64');
}

function captureScreenshotX11() {
  const scrot = findTool('scrot');
  if (scrot) {
    const buffer = execFileSync(scrot, ['-o', '-', '--format', 'png'], { maxBuffer: 50 * 1024 * 1024 });
    return buffer.toString('base64');
  }
  // Fallback to ImageMagick import
  const importTool = findTool('import');
  if (importTool) {
    const buffer = execFileSync(importTool, ['-window', 'root', 'png:-'], { maxBuffer: 50 * 1024 * 1024 });
    return buffer.toString('base64');
  }
  throw new Error('scrot or import (ImageMagick) not found — install scrot for X11 screenshots');
}

/**
 * Capture a full-screen screenshot, returned as base64 PNG.
 */
function captureScreenshot() {
  const ds = detectDisplayServer();
  let result;
  if (ds === 'wayland') {
    result = captureScreenshotWayland();
  } else if (ds === 'x11') {
    result = captureScreenshotX11();
  } else {
    throw new Error('No display server detected — cannot capture screenshot');
  }
  logAction('screenshot', { displayServer: ds, sizeBytes: result.length });
  return result;
}

// ---------------------------------------------------------------------------
// Window listing
// ---------------------------------------------------------------------------

function getOpenWindowsWayland() {
  // Hyprland
  const hyprctl = findTool('hyprctl');
  if (hyprctl) {
    try {
      const output = execFileSync(hyprctl, ['clients', '-j'], { encoding: 'utf8' });
      const clients = JSON.parse(output);
      return clients.map(c => ({
        id: String(c.address || c.pid),
        desktop: String(c.workspace?.id || 0),
        title: c.title || '',
      }));
    } catch (_) {}
  }

  // Sway / wlroots
  const swaymsg = findTool('swaymsg');
  if (swaymsg) {
    try {
      const output = execFileSync(swaymsg, ['-t', 'get_tree'], { encoding: 'utf8' });
      return parseSway(output);
    } catch (_) {}
  }

  return [];
}

function parseSway(jsonStr) {
  const tree = JSON.parse(jsonStr);
  const windows = [];
  function walk(node) {
    if (node.type === 'con' && node.name) {
      windows.push({
        id: String(node.id),
        desktop: String(node.workspace || 0),
        title: node.name,
      });
    }
    if (node.nodes) node.nodes.forEach(walk);
    if (node.floating_nodes) node.floating_nodes.forEach(walk);
  }
  walk(tree);
  return windows;
}

function getOpenWindowsX11() {
  const wmctrl = findTool('wmctrl');
  if (!wmctrl) return [];
  try {
    const output = execFileSync(wmctrl, ['-l'], { encoding: 'utf8' });
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
 * List open windows on the desktop.
 */
function getOpenWindows() {
  const ds = detectDisplayServer();
  const windows = ds === 'wayland' ? getOpenWindowsWayland() : getOpenWindowsX11();
  logAction('getOpenWindows', { displayServer: ds, count: windows.length });
  return windows;
}

// ---------------------------------------------------------------------------
// Input automation
// ---------------------------------------------------------------------------

/**
 * Click at screen coordinates.
 */
function clickAt(x, y) {
  const ds = detectDisplayServer();
  if (ds === 'wayland') {
    const ydotool = findTool('ydotool');
    if (!ydotool) throw new Error('ydotool not found — install ydotool for Wayland input automation');
    execFileSync(ydotool, ['mousemove', '--absolute', '-x', String(x), '-y', String(y)]);
    execFileSync(ydotool, ['click', '0xC0']);
  } else {
    const xdotool = findTool('xdotool');
    if (!xdotool) throw new Error('xdotool not found — install xdotool for X11 input automation');
    execFileSync(xdotool, ['mousemove', String(x), String(y)]);
    execFileSync(xdotool, ['click', '1']);
  }
  logAction('click', { x, y, displayServer: ds });
}

/**
 * Type text at the current cursor position.
 */
function typeText(text) {
  const ds = detectDisplayServer();
  if (ds === 'wayland') {
    const ydotool = findTool('ydotool');
    if (!ydotool) throw new Error('ydotool not found');
    execFileSync(ydotool, ['type', '--', text]);
  } else {
    const xdotool = findTool('xdotool');
    if (!xdotool) throw new Error('xdotool not found');
    execFileSync(xdotool, ['type', '--clearmodifiers', '--', text]);
  }
  logAction('type', { length: text.length, displayServer: ds });
}

/**
 * Scroll at screen coordinates.
 */
function scroll(x, y, direction, amount) {
  const ds = detectDisplayServer();
  amount = Math.max(1, Math.min(amount || 3, 20));

  if (ds === 'wayland') {
    const ydotool = findTool('ydotool');
    if (!ydotool) throw new Error('ydotool not found');
    execFileSync(ydotool, ['mousemove', '--absolute', '-x', String(x), '-y', String(y)]);
    const btn = direction === 'up' ? '0x00040' : '0x00080';
    for (let i = 0; i < amount; i++) {
      execFileSync(ydotool, ['click', btn]);
    }
  } else {
    const xdotool = findTool('xdotool');
    if (!xdotool) throw new Error('xdotool not found');
    execFileSync(xdotool, ['mousemove', String(x), String(y)]);
    const btn = direction === 'up' ? '4' : '5';
    for (let i = 0; i < amount; i++) {
      execFileSync(xdotool, ['click', btn]);
    }
  }
  logAction('scroll', { x, y, direction, amount, displayServer: ds });
}

/**
 * Get display dimensions.
 */
function getDisplayInfo() {
  const ds = detectDisplayServer();
  if (ds === 'wayland') {
    const wlrRandr = findTool('wlr-randr');
    if (wlrRandr) {
      try {
        return execFileSync(wlrRandr, [], { encoding: 'utf8' });
      } catch (_) {}
    }
  } else {
    const xrandr = findTool('xrandr');
    if (xrandr) {
      try {
        return execFileSync(xrandr, ['--current'], { encoding: 'utf8' });
      } catch (_) {}
    }
  }
  return null;
}

module.exports = {
  detectDisplayServer,
  findTool,
  captureScreenshot,
  getOpenWindows,
  clickAt,
  typeText,
  scroll,
  getDisplayInfo,
};
