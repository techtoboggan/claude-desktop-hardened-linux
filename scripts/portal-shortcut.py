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

        # Write to KDE config for auto-assignment
        write_kde_shortcut(shortcut_id, preferred_trigger)

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


def write_kde_shortcut(shortcut_id, trigger):
    """Write shortcut binding to KDE's kglobalshortcutsrc for auto-assignment."""
    trigger_kde = (
        trigger
        .replace("<ctrl>", "Ctrl+")
        .replace("<alt>", "Alt+")
        .replace("<shift>", "Shift+")
        .replace("<super>", "Meta+")
        .replace("space", "Space")
    )
    kde_config = os.path.expanduser("~/.config/kglobalshortcutsrc")
    if not os.path.exists(kde_config):
        return

    try:
        # Read, modify, write — preserving existing content exactly
        lines = open(kde_config).readlines()
        section = "claude-desktop-hardened"
        section_header = f"[{section}]\n"

        # Find or create the section
        section_idx = None
        for i, line in enumerate(lines):
            if line.strip() == f"[{section}]":
                section_idx = i
                break

        if section_idx is not None:
            # Section exists — find the shortcut key line
            key_found = False
            for i in range(section_idx + 1, len(lines)):
                if lines[i].startswith("["):
                    break  # next section
                if lines[i].startswith(f"{shortcut_id}="):
                    current = lines[i].strip().split("=", 1)[1]
                    # Only update if not already assigned
                    if current.startswith(",") or current.startswith("none,"):
                        lines[i] = f"{shortcut_id}={trigger_kde},{trigger_kde},Claude Quick Entry\n"
                    key_found = True
                    break
            if not key_found:
                # Add the key after the section header
                lines.insert(section_idx + 1, f"{shortcut_id}={trigger_kde},{trigger_kde},Claude Quick Entry\n")
        else:
            # Add new section at the end
            lines.append(f"\n[{section}]\n")
            lines.append(f"_k_friendly_name=Claude (Hardened)\n")
            lines.append(f"{shortcut_id}={trigger_kde},{trigger_kde},Claude Quick Entry\n")

        open(kde_config, "w").writelines(lines)
    except Exception:
        pass


if __name__ == "__main__":
    main()
