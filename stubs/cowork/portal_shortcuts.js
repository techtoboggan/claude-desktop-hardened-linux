/**
 * Wayland global shortcuts via XDG Desktop Portal D-Bus protocol.
 *
 * On Wayland, applications can't grab global keyboard shortcuts directly.
 * Instead, they must request them via the org.freedesktop.portal.GlobalShortcuts
 * interface. This module handles that communication.
 *
 * Note: GNOME does not yet implement GlobalShortcuts portal.
 * This will work on KDE Plasma, Hyprland, and Sway with xdg-desktop-portal-wlr.
 */

'use strict';

const { exec } = require('child_process');

/**
 * Check if GlobalShortcuts portal is available.
 */
function isPortalAvailable() {
  return new Promise((resolve) => {
    exec(
      'dbus-send --session --print-reply --dest=org.freedesktop.portal.Desktop ' +
      '/org/freedesktop/portal/desktop ' +
      'org.freedesktop.DBus.Properties.Get ' +
      'string:"org.freedesktop.portal.GlobalShortcuts" string:"version"',
      (err, stdout) => {
        if (err) {
          resolve(false);
        } else {
          resolve(stdout.includes('uint32'));
        }
      }
    );
  });
}

/**
 * Request a global shortcut binding.
 * Placeholder — full implementation requires D-Bus protocol handling.
 */
async function requestShortcut(id, description, preferredTrigger) {
  const available = await isPortalAvailable();
  if (!available) {
    console.warn(
      '[cowork-linux] GlobalShortcuts portal not available. ' +
      'Global shortcuts require KDE Plasma, Hyprland, or Sway with xdg-desktop-portal-wlr. ' +
      'GNOME does not yet support this portal.'
    );
    return false;
  }

  // TODO: Full D-Bus implementation for GlobalShortcuts portal
  // For now, log the intent and return false
  console.log(`[cowork-linux] Shortcut requested: ${id} (${description}) -> ${preferredTrigger}`);
  return false;
}

module.exports = {
  isPortalAvailable,
  requestShortcut,
};
