#!/bin/bash
# claude-desktop-hardened --focus
# Bring the Claude Desktop window to the foreground.
#
# On Wayland, applications cannot steal focus — the compositor controls it.
# This script uses compositor-specific commands to request window activation.
#
# Bind this to a keyboard shortcut in your compositor config:
#
#   Hyprland:  bind = CTRL ALT, Space, exec, claude-desktop-hardened --focus
#   Sway:      bindsym Ctrl+Alt+Space exec claude-desktop-hardened --focus
#   i3:        bindsym Ctrl+Alt+space exec claude-desktop-hardened --focus
#
# On X11, wmctrl is used and works directly.

set -uo pipefail

APP_ID="claude-desktop-hardened"

# Detect display server
if [ -n "${WAYLAND_DISPLAY:-}" ] || [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
    DS="wayland"
elif [ -n "${DISPLAY:-}" ]; then
    DS="x11"
else
    echo "No display server detected" >&2
    exit 1
fi

if [ "$DS" = "wayland" ]; then
    # Hyprland
    if command -v hyprctl >/dev/null 2>&1; then
        ADDR=$(hyprctl clients -j 2>/dev/null | \
            python3 -c "import sys,json; clients=json.load(sys.stdin); match=[c for c in clients if 'claude' in (c.get('class','')+'|'+c.get('initialClass','')).lower()]; print(match[0]['address'] if match else '')" 2>/dev/null)
        if [ -n "$ADDR" ]; then
            hyprctl dispatch focuswindow "address:$ADDR"
            exit 0
        fi
    fi

    # Sway / wlroots
    if command -v swaymsg >/dev/null 2>&1; then
        swaymsg "[app_id=$APP_ID] focus" 2>/dev/null && exit 0
    fi

    # KDE Plasma 6 (via KWin scripting — most reliable on KDE Wayland)
    if [ "${XDG_CURRENT_DESKTOP:-}" = "KDE" ] && command -v gdbus >/dev/null 2>&1; then
        KWIN_SCRIPT=$(mktemp /tmp/kwin-focus-XXXXXX.js)
        cat > "$KWIN_SCRIPT" << 'KWINJS'
const clients = workspace.stackingOrder;
for (let i = 0; i < clients.length; i++) {
    const c = clients[i];
    if (c.resourceClass && c.resourceClass.toString().toLowerCase().includes('claude')) {
        workspace.activeWindow = c;
        break;
    }
}
KWINJS
        gdbus call --session --dest org.kde.KWin --object-path /Scripting \
            --method org.kde.kwin.Scripting.loadScript "$KWIN_SCRIPT" 2>/dev/null
        gdbus call --session --dest org.kde.KWin --object-path /Scripting \
            --method org.kde.kwin.Scripting.start 2>/dev/null
        rm -f "$KWIN_SCRIPT"
        exit 0
    fi

    # KDE fallback via kdotool
    if command -v kdotool >/dev/null 2>&1; then
        WID=$(kdotool search --class "$APP_ID" 2>/dev/null | head -1)
        if [ -n "$WID" ]; then
            kdotool windowactivate "$WID" && exit 0
        fi
    fi

    # GNOME (via gdbus → gnome-shell eval)
    if [ "${XDG_CURRENT_DESKTOP:-}" = "GNOME" ] && command -v gdbus >/dev/null 2>&1; then
        gdbus call --session --dest org.gnome.Shell \
            --object-path /org/gnome/Shell \
            --method org.gnome.Shell.Eval \
            "global.get_window_actors().find(a => a.meta_window.get_wm_class_instance()?.includes('claude'))?.meta_window.activate(global.get_current_time())" \
            2>/dev/null && exit 0
    fi

    echo "Could not focus Claude window — no supported compositor command found" >&2
    echo "Try binding this script to a shortcut in your compositor config" >&2
    exit 1
else
    # X11: wmctrl
    if command -v wmctrl >/dev/null 2>&1; then
        wmctrl -x -a "$APP_ID" 2>/dev/null && exit 0
    fi

    # X11: xdotool fallback
    if command -v xdotool >/dev/null 2>&1; then
        WID=$(xdotool search --class "$APP_ID" 2>/dev/null | head -1)
        if [ -n "$WID" ]; then
            xdotool windowactivate "$WID" && exit 0
        fi
    fi

    echo "Could not focus Claude window — install wmctrl or xdotool" >&2
    exit 1
fi
