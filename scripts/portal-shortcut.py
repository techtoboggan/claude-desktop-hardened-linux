#!/usr/bin/env python3
"""
Register Ctrl+Alt+Space global shortcut via XDG Desktop Portal.

Uses a single D-Bus connection for the full lifecycle:
  1. CreateSession
  2. BindShortcuts
  3. Listen for Activated signal

Outputs "ACTIVATED" on stdout when the shortcut is pressed.
Designed to be spawned by the Electron main process and monitored.

Requires: python3 + dbus (standard on most Linux desktops)
"""

import os
import sys
import signal

try:
    import dbus
    from dbus.mainloop.glib import DBusGMainLoop
    from gi.repository import GLib
except ImportError:
    print("UNAVAILABLE", flush=True)
    sys.exit(0)

PORTAL_BUS = "org.freedesktop.portal.Desktop"
PORTAL_PATH = "/org/freedesktop/portal/desktop"
SHORTCUTS_IFACE = "org.freedesktop.portal.GlobalShortcuts"
REQUEST_IFACE = "org.freedesktop.portal.Request"

def main():
    DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    loop = GLib.MainLoop()

    # Clean exit on SIGTERM
    signal.signal(signal.SIGTERM, lambda *_: loop.quit())
    signal.signal(signal.SIGINT, lambda *_: loop.quit())

    portal = bus.get_object(PORTAL_BUS, PORTAL_PATH)
    shortcuts = dbus.Interface(portal, SHORTCUTS_IFACE)

    sender = bus.get_unique_name().replace(":", "").replace(".", "_")
    session_token = "claude_session"
    session_path = f"/org/freedesktop/portal/desktop/session/{sender}/{session_token}"

    # Step 1: CreateSession
    try:
        shortcuts.CreateSession(
            dbus.Dictionary({
                "handle_token": dbus.String("claude_req"),
                "session_handle_token": dbus.String(session_token),
            }, signature="sv")
        )
    except dbus.exceptions.DBusException as e:
        print(f"PORTAL_ERROR: {e}", flush=True)
        sys.exit(1)

    # Step 2: BindShortcuts
    shortcut_id = "quick-entry"
    preferred_trigger = os.environ.get("CLAUDE_SHORTCUT", "<ctrl><alt>space")

    try:
        shortcuts.BindShortcuts(
            dbus.ObjectPath(session_path),
            dbus.Array([
                dbus.Struct([
                    dbus.String(shortcut_id),
                    dbus.Dictionary({
                        "description": dbus.String("Claude Quick Entry", variant_level=1),
                        "preferred_trigger": dbus.String(preferred_trigger, variant_level=1),
                    }, signature="sv"),
                ], signature="sa{sv}"),
            ], signature="(sa{sv})"),
            dbus.String(""),  # parent_window
            dbus.Dictionary({}, signature="sv"),
        )
    except dbus.exceptions.DBusException as e:
        print(f"BIND_ERROR: {e}", flush=True)
        sys.exit(1)

    # KDE workaround: the portal's preferred_trigger is treated as a suggestion,
    # not an assignment. Write the binding directly to kglobalshortcutsrc so
    # Ctrl+Alt+Space is auto-assigned on first registration.
    trigger_gtk = preferred_trigger.replace("<ctrl>", "Ctrl+").replace("<alt>", "Alt+").replace("<shift>", "Shift+").replace("space", "Space")
    kde_config = os.path.expanduser("~/.config/kglobalshortcutsrc")
    try:
        import configparser
        config = configparser.ConfigParser(interpolation=None)
        config.optionxform = str  # preserve case
        config.read(kde_config)
        section = "claude-desktop-hardened"
        if not config.has_section(section):
            config.add_section(section)
        current = config.get(section, shortcut_id, fallback="")
        # Only set if not already assigned (don't override user customizations)
        if not current or current.startswith(",") or current.startswith("none,"):
            config.set(section, shortcut_id, f"{trigger_gtk},{trigger_gtk},Claude Quick Entry")
            config.set(section, "_k_friendly_name", "Claude (Hardened)")
            with open(kde_config, "w") as f:
                config.write(f, space_around_delimiters=False)
    except Exception:
        pass  # Non-KDE or config not writable

    print("READY", flush=True)

    # Step 3: Listen for Activated signal
    def on_activated(session_handle, shortcut_id, timestamp, options):
        print("ACTIVATED", flush=True)

    bus.add_signal_receiver(
        on_activated,
        signal_name="Activated",
        dbus_interface=SHORTCUTS_IFACE,
        path=session_path,
    )

    # Run the event loop
    loop.run()

if __name__ == "__main__":
    main()
