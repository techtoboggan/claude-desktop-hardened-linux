#!/bin/bash
# Display server detection and tool lists for claude-desktop-hardened.
# Sourced by the launcher, doctor, and build scripts.

detect_display_server() {
    if [ -n "$WAYLAND_DISPLAY" ] || [ "$XDG_SESSION_TYPE" = "wayland" ]; then
        echo "wayland"
    elif [ -n "$DISPLAY" ]; then
        echo "x11"
    else
        echo "headless"
    fi
}

# Computer Use tools per display server
X11_TOOLS="wmctrl xdotool scrot xclip xrandr"
WAYLAND_TOOLS="grim slurp wl-copy ydotool wlr-randr"
