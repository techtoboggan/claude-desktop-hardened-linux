#!/usr/bin/env python3
"""
Register Ctrl+Alt+Space global shortcut via XDG Desktop Portal.

Uses a single D-Bus connection for the full lifecycle:
  1. CreateSession (wait for Response signal)
  2. BindShortcuts (wait for Response signal)
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

    signal.signal(signal.SIGTERM, lambda *_: loop.quit())
    signal.signal(signal.SIGINT, lambda *_: loop.quit())

    portal = bus.get_object(PORTAL_BUS, PORTAL_PATH)
    shortcuts = dbus.Interface(portal, SHORTCUTS_IFACE)

    sender = bus.get_unique_name().replace(":", "").replace(".", "_")
    session_token = "claude_session"
    session_path = f"/org/freedesktop/portal/desktop/session/{sender}/{session_token}"

    shortcut_id = "quick-entry"
    preferred_trigger = os.environ.get("CLAUDE_SHORTCUT", "<ctrl><alt>space")

    # Step 1: CreateSession and wait for Response
    def on_session_response(response_code, results):
        if response_code != 0:
            print(f"PORTAL_ERROR: CreateSession failed with code {response_code}", flush=True)
            loop.quit()
            return

        # Step 2: BindShortcuts
        try:
            bind_req = shortcuts.BindShortcuts(
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
                dbus.String(""),
                dbus.Dictionary({"handle_token": dbus.String("claude_bind", variant_level=1)}, signature="sv"),
            )

            # Wait for BindShortcuts response
            bus.add_signal_receiver(
                on_bind_response,
                signal_name="Response",
                dbus_interface=REQUEST_IFACE,
                path=str(bind_req),
            )
        except dbus.exceptions.DBusException as e:
            print(f"BIND_ERROR: {e}", flush=True)
            loop.quit()

    def on_bind_response(response_code, results):
        if response_code != 0:
            print(f"BIND_ERROR: BindShortcuts failed with code {response_code}", flush=True)
            loop.quit()
            return

        # Assign the actual keybinding via kglobalaccel D-Bus
        assign_kde_shortcut(bus, shortcut_id, preferred_trigger)

        print("READY", flush=True)

        # Step 3: Listen for Activated signal
        bus.add_signal_receiver(
            on_activated,
            signal_name="Activated",
            dbus_interface=SHORTCUTS_IFACE,
            path=session_path,
        )

    def on_activated(session_handle, shortcut_id, timestamp, options):
        print("ACTIVATED", flush=True)

    # Fire CreateSession
    try:
        create_req = shortcuts.CreateSession(
            dbus.Dictionary({
                "handle_token": dbus.String("claude_create"),
                "session_handle_token": dbus.String(session_token),
            }, signature="sv")
        )

        # Listen for the Response on the request path
        bus.add_signal_receiver(
            on_session_response,
            signal_name="Response",
            dbus_interface=REQUEST_IFACE,
            path=str(create_req),
        )
    except dbus.exceptions.DBusException as e:
        print(f"PORTAL_ERROR: {e}", flush=True)
        sys.exit(1)

    # Timeout: if nothing happens in 10 seconds, the portal isn't working
    def on_timeout():
        print("PORTAL_TIMEOUT", flush=True)
        loop.quit()
        return False

    GLib.timeout_add(10000, on_timeout)

    loop.run()


def assign_kde_shortcut(bus, shortcut_id, trigger):
    """Assign shortcut key via kglobalaccel D-Bus (the authoritative source on KDE)."""
    # Convert XDG trigger format to Qt key code
    # Qt: Ctrl=0x04000000, Alt=0x08000000, Shift=0x02000000, Meta=0x10000000
    qt_mods = 0
    key_name = trigger
    for mod, qt_val in [("<ctrl>", 0x04000000), ("<alt>", 0x08000000),
                        ("<shift>", 0x02000000), ("<super>", 0x10000000)]:
        if mod in key_name:
            qt_mods |= qt_val
            key_name = key_name.replace(mod, "")

    # Map key name to Qt key code
    qt_keys = {"space": 0x20, "return": 0x01000004, "escape": 0x01000000,
               "tab": 0x01000001, "backspace": 0x01000003}
    qt_key = qt_keys.get(key_name.lower(), ord(key_name.upper()) if len(key_name) == 1 else 0)
    qt_code = qt_mods | qt_key

    if qt_code == 0:
        return

    try:
        kga = bus.get_object("org.kde.kglobalaccel", "/kglobalaccel")
        iface = dbus.Interface(kga, "org.kde.KGlobalAccel")

        action_id = dbus.Array([
            dbus.String("claude-desktop-hardened"),
            dbus.String(shortcut_id),
            dbus.String("Claude (Hardened)"),
            dbus.String("Claude Quick Entry"),
        ], signature="s")

        # Register the action
        iface.doRegister(action_id)

        # Assign the key
        iface.setForeignShortcut(action_id, dbus.Array([dbus.Int32(qt_code)], signature="i"))
    except Exception:
        pass  # Not on KDE, or kglobalaccel not available


if __name__ == "__main__":
    main()
