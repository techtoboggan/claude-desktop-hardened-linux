/**
 * Enhanced Linux stub for claude-native module.
 *
 * This replaces the Windows-specific native module with a JavaScript
 * implementation that provides keyboard constants and Cowork-aware
 * platform information.
 */

'use strict';

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
};
