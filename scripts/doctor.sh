#!/bin/bash
# claude-desktop-hardened --doctor
# System diagnostic for Claude Desktop Hardened Linux
set -uo pipefail

PASS=0
WARN=0
FAIL=0

check_pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; ((PASS++)) || true; }
check_warn() { printf '  \033[33m⚠\033[0m %s\n' "$*"; ((WARN++)) || true; }
check_fail() { printf '  \033[31m✗\033[0m %s\n' "$*"; ((FAIL++)) || true; }
section()    { printf '\n\033[1m[ %s ]\033[0m\n' "$*"; }

echo "Claude Desktop Hardened — System Diagnostic"
echo "============================================"

# 1. Electron
section "Electron"
if command -v electron >/dev/null 2>&1; then
    ELECTRON_VER=$(electron --version 2>/dev/null | tr -d 'v')
    check_pass "Electron $ELECTRON_VER ($(command -v electron))"
else
    check_fail "Electron not found in PATH"
fi

# 2. chrome-sandbox permissions
section "Chrome Sandbox"
SANDBOX_FOUND=false
for p in /usr/lib64/claude-desktop-hardened/app.asar.unpacked/node_modules/electron/dist/chrome-sandbox \
         /usr/lib/claude-desktop-hardened/app.asar.unpacked/node_modules/electron/dist/chrome-sandbox; do
    if [ -f "$p" ]; then
        SANDBOX_FOUND=true
        PERMS=$(stat -c '%a' "$p")
        OWNER=$(stat -c '%U' "$p")
        if [ "$PERMS" = "4755" ] && [ "$OWNER" = "root" ]; then
            check_pass "chrome-sandbox: correct setuid permissions ($p)"
        else
            check_fail "chrome-sandbox: wrong permissions $PERMS owned by $OWNER (need 4755 root) at $p"
        fi
        break
    fi
done
if ! $SANDBOX_FOUND; then
    # Check via electron binary location
    if command -v electron >/dev/null 2>&1; then
        ELECTRON_DIR="$(dirname "$(readlink -f "$(command -v electron)")")"
        if [ -f "$ELECTRON_DIR/chrome-sandbox" ]; then
            PERMS=$(stat -c '%a' "$ELECTRON_DIR/chrome-sandbox")
            OWNER=$(stat -c '%U' "$ELECTRON_DIR/chrome-sandbox")
            if [ "$PERMS" = "4755" ] && [ "$OWNER" = "root" ]; then
                check_pass "chrome-sandbox: correct setuid permissions ($ELECTRON_DIR/chrome-sandbox)"
            else
                check_fail "chrome-sandbox: wrong permissions $PERMS owned by $OWNER at $ELECTRON_DIR/chrome-sandbox"
            fi
        else
            check_warn "chrome-sandbox not found at $ELECTRON_DIR/chrome-sandbox"
        fi
    else
        check_warn "chrome-sandbox not found (electron not in PATH)"
    fi
fi

# 3. Bubblewrap
section "Bubblewrap"
if command -v bwrap >/dev/null 2>&1; then
    BWRAP_VER=$(bwrap --version 2>/dev/null | head -1)
    check_pass "bubblewrap: $BWRAP_VER"
else
    check_fail "bubblewrap not found — required for sandboxed Cowork sessions"
fi

# 4. Display server
section "Display Server"
if [ -n "${WAYLAND_DISPLAY:-}" ] || [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
    check_pass "Wayland session detected"
    DS="wayland"
elif [ -n "${DISPLAY:-}" ]; then
    check_pass "X11 session detected (DISPLAY=$DISPLAY)"
    DS="x11"
else
    check_warn "No display server detected — running headless?"
    DS="headless"
fi

# 5. Display-server-specific tools
section "Computer Use Tools ($DS)"
if [ "$DS" = "wayland" ]; then
    for tool in grim slurp wl-copy ydotool wlr-randr; do
        if command -v "$tool" >/dev/null 2>&1; then
            check_pass "$tool"
        else
            check_warn "$tool not found (optional, needed for Computer Use)"
        fi
    done
elif [ "$DS" = "x11" ]; then
    for tool in wmctrl xdotool scrot xclip xrandr; do
        if command -v "$tool" >/dev/null 2>&1; then
            check_pass "$tool"
        else
            check_warn "$tool not found (optional, needed for Computer Use)"
        fi
    done
fi

# 6. Global shortcuts portal (Wayland)
if [ "$DS" = "wayland" ]; then
    section "Global Shortcuts (Wayland)"
    if command -v dbus-send >/dev/null 2>&1; then
        if dbus-send --session --print-reply --dest=org.freedesktop.portal.Desktop \
            /org/freedesktop/portal/desktop \
            org.freedesktop.DBus.Properties.Get \
            string:"org.freedesktop.portal.GlobalShortcuts" string:"version" 2>/dev/null | grep -q "uint32"; then
            check_pass "GlobalShortcuts portal available (Ctrl+Alt+Space should work)"
        else
            check_warn "GlobalShortcuts portal not available"
            echo "         Ctrl+Alt+Space won't work natively. Bind a compositor shortcut instead:"
            echo "         Hyprland: bind = CTRL ALT, Space, exec, claude-desktop-hardened --focus"
            echo "         Sway:    bindsym Ctrl+Alt+Space exec claude-desktop-hardened --focus"
        fi
    fi
fi

# MCP config
section "MCP Configuration"
MCP_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/Claude/claude_desktop_config.json"
if [ -f "$MCP_CONFIG" ]; then
    if python3 -c "import json; json.load(open('$MCP_CONFIG'))" 2>/dev/null; then
        check_pass "MCP config is valid JSON ($MCP_CONFIG)"
    else
        check_fail "MCP config has invalid JSON ($MCP_CONFIG)"
    fi
else
    check_warn "No MCP config found at $MCP_CONFIG (create one to use MCP servers)"
fi

# 7. Claude Code CLI
section "Claude Code CLI"
if command -v claude >/dev/null 2>&1; then
    CLAUDE_VER=$(claude --version 2>/dev/null | head -1)
    check_pass "Claude Code CLI: $CLAUDE_VER ($(command -v claude))"
else
    check_fail "Claude Code CLI not found — Cowork will not function"
fi

# 8. Node.js
section "Node.js"
if command -v node >/dev/null 2>&1; then
    NODE_VER=$(node --version 2>/dev/null)
    NODE_MAJOR=$(echo "$NODE_VER" | sed 's/v//' | cut -d. -f1)
    if [ "$NODE_MAJOR" -ge 18 ] 2>/dev/null; then
        check_pass "Node.js $NODE_VER"
    else
        check_fail "Node.js $NODE_VER (>= 18 required)"
    fi
else
    check_fail "Node.js not found"
fi

# 9. Keyring / secrets service
section "Keyring"
if command -v dbus-send >/dev/null 2>&1; then
    if dbus-send --session --print-reply --dest=org.freedesktop.DBus \
        /org/freedesktop/DBus org.freedesktop.DBus.ListNames 2>/dev/null | \
        grep -q "org.freedesktop.secrets"; then
        check_pass "Secret Service (org.freedesktop.secrets) available"
    else
        check_warn "No Secret Service found — will use basic password store"
    fi
else
    check_warn "dbus-send not available — cannot check keyring"
fi

# Summary
echo
echo "============================================"
printf "Summary: \033[32m%d passed\033[0m, \033[33m%d warnings\033[0m, \033[31m%d failures\033[0m\n" "$PASS" "$WARN" "$FAIL"

if [ "$FAIL" -gt 0 ]; then
    echo
    echo "Some checks failed. Fix the issues above for full functionality."
    exit 1
fi
