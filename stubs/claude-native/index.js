/**
 * Enhanced Linux stub for claude-native module.
 *
 * This replaces the macOS/Windows native module with a JavaScript
 * implementation that provides keyboard constants, input automation
 * (via xdotool/ydotool), and Cowork-aware platform information.
 */

'use strict';

const { execFileSync } = require('child_process');
const fs = require('fs');

// Keyboard key codes (matching the Windows native module's enum values)
const KeyboardKey = {
  Backspace: 43,
  Tab: 280,
  Enter: 261,
  Shift: 272,
  Control: 61,
  Alt: 40,
  CapsLock: 56,
  Escape: 85,
  Space: 276,
  PageUp: 251,
  PageDown: 250,
  End: 83,
  Home: 154,
  LeftArrow: 175,
  UpArrow: 282,
  RightArrow: 262,
  DownArrow: 81,
  Delete: 79,
  Meta: 187,
  // Extended keys
  F1: 86, F2: 87, F3: 88, F4: 89, F5: 90,
  F6: 91, F7: 92, F8: 93, F9: 94, F10: 95,
  F11: 96, F12: 97,
  // Number keys
  Digit0: 27, Digit1: 18, Digit2: 19, Digit3: 20, Digit4: 21,
  Digit5: 23, Digit6: 22, Digit7: 26, Digit8: 28, Digit9: 25,
  // Letter keys
  KeyA: 0, KeyB: 11, KeyC: 8, KeyD: 2, KeyE: 14,
  KeyF: 3, KeyG: 5, KeyH: 4, KeyI: 34, KeyJ: 38,
  KeyK: 40, KeyL: 37, KeyM: 46, KeyN: 45, KeyO: 31,
  KeyP: 35, KeyQ: 12, KeyR: 15, KeyS: 1, KeyT: 17,
  KeyU: 32, KeyV: 9, KeyW: 13, KeyX: 7, KeyY: 16,
  KeyZ: 6,
};

Object.freeze(KeyboardKey);

// ---------------------------------------------------------------------------
// Input automation helpers (xdotool for X11, ydotool for Wayland)
// ---------------------------------------------------------------------------

const TOOL_PATHS = ['/usr/bin/', '/usr/local/bin/'];

function findTool(name) {
  for (const prefix of TOOL_PATHS) {
    const p = prefix + name;
    try { fs.accessSync(p, fs.constants.X_OK); return p; } catch (_) {}
  }
  return null;
}

function isWayland() {
  return !!(process.env.WAYLAND_DISPLAY || process.env.XDG_SESSION_TYPE === 'wayland');
}

// Map macOS-style key names to xdotool/ydotool key names
const KEY_MAP = {
  command: 'super', meta: 'super', cmd: 'super',
  control: 'ctrl', option: 'alt',
  return: 'Return', enter: 'Return',
  escape: 'Escape', esc: 'Escape',
  space: 'space', tab: 'Tab',
  backspace: 'BackSpace', delete: 'Delete',
  up: 'Up', down: 'Down', left: 'Left', right: 'Right',
  home: 'Home', end: 'End', pageup: 'Prior', pagedown: 'Next',
  shift: 'shift', capslock: 'Caps_Lock',
  f1: 'F1', f2: 'F2', f3: 'F3', f4: 'F4', f5: 'F5', f6: 'F6',
  f7: 'F7', f8: 'F8', f9: 'F9', f10: 'F10', f11: 'F11', f12: 'F12',
};

function translateKey(k) {
  const lower = k.toLowerCase();
  if (KEY_MAP[lower]) return KEY_MAP[lower];
  // Single character keys pass through
  if (k.length === 1) return k;
  return k;
}

module.exports = {
  // Keyboard constants
  KeyboardKey,

  // Platform info (spoofed for Cowork compatibility)
  getWindowsVersion: () => '10.0.0',
  getPlatform: () => 'linux',
  getArch: () => process.arch,

  // Window effects — no-op on Linux (these are Windows DWM-specific)
  setWindowEffect: () => {},
  removeWindowEffect: () => {},

  // Window state
  getIsMaximized: () => false,

  // Taskbar/dock integration — no-op (handled by DE)
  flashFrame: () => {},
  clearFlashFrame: () => {},
  setProgressBar: () => {},
  clearProgressBar: () => {},
  setOverlayIcon: () => {},
  clearOverlayIcon: () => {},

  // Notifications — delegate to Electron's built-in notification API
  showNotification: (title, body) => {
    try {
      const { Notification } = require('electron');
      if (Notification.isSupported()) {
        new Notification({ title, body }).show();
      }
    } catch (_) {
      // Fallback: no-op if electron not available in this context
    }
  },

  // Cowork-specific: feature support flags
  isCoworkSupported: () => true,
  isVMSupported: () => true,

  // Window focus tracking — used by the quick-capture window to restore focus
  // to the previously active app after submitting a prompt. No HWND equivalent
  // on Linux; return null so callers fall back gracefully.
  getActiveWindowHandle: () => null,
  setForegroundWindow: () => false,

  // -------------------------------------------------------------------------
  // Computer Use — input automation (called by Zm() in the minified app code)
  // -------------------------------------------------------------------------

  async moveMouse(x, y, _animate) {
    if (isWayland()) {
      const ydotool = findTool('ydotool');
      if (!ydotool) throw new Error('ydotool not found');
      execFileSync(ydotool, ['mousemove', '--absolute', '-x', String(Math.round(x)), '-y', String(Math.round(y))]);
    } else {
      const xdotool = findTool('xdotool');
      if (!xdotool) throw new Error('xdotool not found');
      execFileSync(xdotool, ['mousemove', String(Math.round(x)), String(Math.round(y))]);
    }
  },

  async mouseButton(button, action, count) {
    const btn = button === 'right' ? (isWayland() ? '0xC1' : '3')
              : button === 'middle' ? (isWayland() ? '0xC2' : '2')
              : (isWayland() ? '0xC0' : '1'); // left default

    if (isWayland()) {
      const ydotool = findTool('ydotool');
      if (!ydotool) throw new Error('ydotool not found');
      if (action === 'press') {
        execFileSync(ydotool, ['click', '--next-delay', '0', '-D', '0', btn]);
      } else if (action === 'release') {
        execFileSync(ydotool, ['click', '--next-delay', '0', '-U', '0', btn]);
      } else {
        // click (default)
        const n = count || 1;
        for (let i = 0; i < n; i++) {
          execFileSync(ydotool, ['click', btn]);
        }
      }
    } else {
      const xdotool = findTool('xdotool');
      if (!xdotool) throw new Error('xdotool not found');
      if (action === 'press') {
        execFileSync(xdotool, ['mousedown', btn]);
      } else if (action === 'release') {
        execFileSync(xdotool, ['mouseup', btn]);
      } else {
        const n = count || 1;
        const args = ['click'];
        if (n > 1) args.push('--repeat', String(n));
        args.push(btn);
        execFileSync(xdotool, args);
      }
    }
  },

  async mouseScroll(amount, direction) {
    const scrollAmt = Math.abs(amount) || 3;
    if (isWayland()) {
      const ydotool = findTool('ydotool');
      if (!ydotool) throw new Error('ydotool not found');
      // ydotool uses wheel events: button 4=up, 5=down, 6=left, 7=right
      if (direction === 'horizontal') {
        const btn = amount > 0 ? '0x00100' : '0x00200'; // right : left
        for (let i = 0; i < scrollAmt; i++) execFileSync(ydotool, ['click', btn]);
      } else {
        const btn = amount > 0 ? '0x00080' : '0x00040'; // down : up
        for (let i = 0; i < scrollAmt; i++) execFileSync(ydotool, ['click', btn]);
      }
    } else {
      const xdotool = findTool('xdotool');
      if (!xdotool) throw new Error('xdotool not found');
      if (direction === 'horizontal') {
        const btn = amount > 0 ? '7' : '6';
        for (let i = 0; i < scrollAmt; i++) execFileSync(xdotool, ['click', btn]);
      } else {
        const btn = amount > 0 ? '5' : '4';
        for (let i = 0; i < scrollAmt; i++) execFileSync(xdotool, ['click', btn]);
      }
    }
  },

  async mouseLocation() {
    if (isWayland()) {
      // ydotool doesn't expose cursor position; use Electron screen API
      try {
        const { screen } = require('electron');
        const point = screen.getCursorScreenPoint();
        return { x: point.x, y: point.y };
      } catch (_) {
        return { x: 0, y: 0 };
      }
    } else {
      const xdotool = findTool('xdotool');
      if (!xdotool) return { x: 0, y: 0 };
      try {
        const out = execFileSync(xdotool, ['getmouselocation'], { encoding: 'utf8' });
        const xm = out.match(/x:(\d+)/);
        const ym = out.match(/y:(\d+)/);
        return { x: parseInt(xm?.[1] || '0'), y: parseInt(ym?.[1] || '0') };
      } catch (_) {
        return { x: 0, y: 0 };
      }
    }
  },

  async keys(keyArray) {
    const translated = keyArray.map(translateKey);
    if (isWayland()) {
      const ydotool = findTool('ydotool');
      if (!ydotool) throw new Error('ydotool not found');
      // ydotool key expects key names separated by space for simultaneous press
      execFileSync(ydotool, ['key', translated.join('+')]);
    } else {
      const xdotool = findTool('xdotool');
      if (!xdotool) throw new Error('xdotool not found');
      execFileSync(xdotool, ['key', translated.join('+')]);
    }
  },

  async typeText(text) {
    if (isWayland()) {
      const ydotool = findTool('ydotool');
      if (!ydotool) throw new Error('ydotool not found');
      execFileSync(ydotool, ['type', '--', text]);
    } else {
      const xdotool = findTool('xdotool');
      if (!xdotool) throw new Error('xdotool not found');
      execFileSync(xdotool, ['type', '--clearmodifiers', '--', text]);
    }
  },

  getFrontmostAppInfo() {
    if (isWayland()) {
      // Try hyprctl
      const hyprctl = findTool('hyprctl');
      if (hyprctl) {
        try {
          const out = execFileSync(hyprctl, ['activewindow', '-j'], { encoding: 'utf8' });
          const win = JSON.parse(out);
          return { bundleId: win.class || win.initialClass || 'unknown', appName: win.title || 'Unknown' };
        } catch (_) {}
      }
      // Try swaymsg
      const swaymsg = findTool('swaymsg');
      if (swaymsg) {
        try {
          const out = execFileSync(swaymsg, ['-t', 'get_tree'], { encoding: 'utf8' });
          const tree = JSON.parse(out);
          // Find focused node
          function findFocused(node) {
            if (node.focused) return node;
            for (const child of (node.nodes || []).concat(node.floating_nodes || [])) {
              const found = findFocused(child);
              if (found) return found;
            }
            return null;
          }
          const focused = findFocused(tree);
          if (focused) return { bundleId: focused.app_id || 'unknown', appName: focused.name || 'Unknown' };
        } catch (_) {}
      }
      return null;
    }

    // X11
    const xdotool = findTool('xdotool');
    if (!xdotool) return null;
    try {
      const winId = execFileSync(xdotool, ['getactivewindow'], { encoding: 'utf8' }).trim();
      const name = execFileSync(xdotool, ['getactivewindow', 'getwindowname'], { encoding: 'utf8' }).trim();
      let wmClass = 'unknown';
      try {
        const xprop = findTool('xprop');
        if (xprop) {
          const out = execFileSync(xprop, ['-id', winId, 'WM_CLASS'], { encoding: 'utf8' });
          const m = out.match(/"([^"]+)"/);
          if (m) wmClass = m[1];
        }
      } catch (_) {}
      return { bundleId: wmClass, appName: name };
    } catch (_) {
      return null;
    }
  },
};
