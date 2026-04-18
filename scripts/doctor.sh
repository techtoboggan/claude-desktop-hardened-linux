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
check_hint() { printf '    \033[2m→ %s\033[0m\n' "$*"; }
section()    { printf '\n\033[1m[ %s ]\033[0m\n' "$*"; }

# Detect package manager for install hints
detect_pkg_manager() {
    if command -v dnf >/dev/null 2>&1;    then echo "dnf"
    elif command -v apt >/dev/null 2>&1;  then echo "apt"
    elif command -v pacman >/dev/null 2>&1; then echo "pacman"
    else echo "unknown"; fi
}
PKG_MANAGER=$(detect_pkg_manager)

install_hint() {
    # install_hint <dnf-pkg> <apt-pkg> <pacman-pkg>
    local pkg_dnf="$1" pkg_apt="$2" pkg_pac="$3"
    case "$PKG_MANAGER" in
        dnf)    check_hint "sudo dnf install $pkg_dnf" ;;
        apt)    check_hint "sudo apt install $pkg_apt" ;;
        pacman) check_hint "sudo pacman -S $pkg_pac" ;;
    esac
}

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
# Source shared detection if available, otherwise inline fallback
SHARE_DIR="$(dirname "$0")"
if [ -f "$SHARE_DIR/display-server.sh" ]; then
    # shellcheck source=../lib/display-server.sh
    . "$SHARE_DIR/display-server.sh"
    DS=$(detect_display_server)
else
    # Fallback for running outside install tree
    if [ -n "${WAYLAND_DISPLAY:-}" ] || [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
        DS="wayland"
    elif [ -n "${DISPLAY:-}" ]; then
        DS="x11"
    else
        DS="headless"
    fi
fi
case "$DS" in
    wayland)  check_pass "Wayland session detected" ;;
    x11)      check_pass "X11 session detected (DISPLAY=$DISPLAY)" ;;
    headless) check_warn "No display server detected — running headless?" ;;
esac

# 5. Display-server-specific tools
section "Computer Use Tools ($DS)"
CU_MISSING=()
if [ "$DS" = "wayland" ]; then
    _cu_tools=(
        "grim:screenshots:grim:grim:grim"
        "ydotool:mouse/keyboard input:ydotool:ydotool:ydotool"
        "wl-copy:clipboard:wl-clipboard:wl-tools:wl-clipboard"
        "slurp:region selection:slurp:slurp:slurp"
        "wlr-randr:display info:wlr-randr:wlr-randr:wlr-randr"
    )
    for entry in "${_cu_tools[@]}"; do
        IFS=: read -r tool purpose pkg_dnf pkg_apt pkg_pac <<< "$entry"
        if command -v "$tool" >/dev/null 2>&1; then
            check_pass "$tool ($purpose)"
        else
            check_warn "$tool not found — needed for $purpose in Computer Use"
            install_hint "$pkg_dnf" "$pkg_apt" "$pkg_pac"
            CU_MISSING+=("$tool")
        fi
    done

    # ydotool requires its daemon (ydotoold) — silent failure without it
    if command -v ydotool >/dev/null 2>&1; then
        if systemctl is-active --quiet ydotool.service 2>/dev/null || \
           systemctl --user is-active --quiet ydotool.service 2>/dev/null; then
            check_pass "ydotoold daemon running"
        else
            check_fail "ydotoold daemon not running — input automation will silently fail"
            check_hint "sudo systemctl enable --now ydotool"
            CU_MISSING+=("ydotoold")
        fi
    fi

elif [ "$DS" = "x11" ]; then
    _cu_tools=(
        "xdotool:mouse/keyboard input:xdotool:xdotool:xdotool"
        "scrot:screenshots:scrot:scrot:scrot"
        "wmctrl:window listing:wmctrl:wmctrl:wmctrl"
        "xclip:clipboard:xclip:xclip:xclip"
        "xrandr:display info:xrandr:x11-xserver-utils:xorg-xrandr"
    )
    for entry in "${_cu_tools[@]}"; do
        IFS=: read -r tool purpose pkg_dnf pkg_apt pkg_pac <<< "$entry"
        if command -v "$tool" >/dev/null 2>&1; then
            check_pass "$tool ($purpose)"
        else
            check_warn "$tool not found — needed for $purpose in Computer Use"
            install_hint "$pkg_dnf" "$pkg_apt" "$pkg_pac"
            CU_MISSING+=("$tool")
        fi
    done
fi

if [ ${#CU_MISSING[@]} -gt 0 ]; then
    echo
    if [ "$DS" = "wayland" ]; then
        check_hint "Install all at once: sudo dnf install claude-desktop-hardened-computeruse"
        check_hint "  (or: sudo dnf install grim ydotool wl-clipboard slurp wlr-randr && sudo systemctl enable --now ydotool)"
    elif [ "$DS" = "x11" ]; then
        check_hint "Install all at once: sudo dnf install claude-desktop-hardened-computeruse"
        check_hint "  (or: sudo dnf install xdotool scrot wmctrl xclip xrandr)"
    fi
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

# 10. Custom model backend (only if user has configured one)
#
# If any ANTHROPIC_* env var is set, echo the resolved config (redacting
# anything that looks like a secret) and probe ANTHROPIC_BASE_URL for
# reachability. Helps users confirm their LiteLLM / LM Studio / Ollama /
# OpenRouter setup BEFORE launching a session and finding out in the logs.
redact_secret() {
    # Show the first 4 chars + "…" + the last 4, or a placeholder if too short.
    local v="$1"
    local len=${#v}
    if [ "$len" -le 10 ]; then
        echo "****"
    else
        printf '%s…%s (%d chars)' "${v:0:4}" "${v: -4}" "$len"
    fi
}

if [ -n "${ANTHROPIC_BASE_URL:-}${ANTHROPIC_API_KEY:-}${ANTHROPIC_AUTH_TOKEN:-}${ANTHROPIC_MODEL:-}" ]; then
    section "Custom Model Backend"

    if [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
        check_pass "ANTHROPIC_BASE_URL = $ANTHROPIC_BASE_URL"
        if command -v curl >/dev/null 2>&1; then
            # Probe TCP + TLS. Even 401/404 means the socket is up.
            RC=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$ANTHROPIC_BASE_URL" 2>&1)
            if [[ "$RC" =~ ^[2-5][0-9][0-9]$ ]]; then
                check_pass "Backend reachable (HTTP $RC)"
            elif [ "$RC" = "000" ]; then
                check_fail "Backend unreachable (connection refused / DNS fail / TLS error)"
                check_hint "Verify the service is running on the specified URL"
                check_hint "For self-signed TLS: run behind a trusted cert or use http://"
            else
                check_warn "Backend probe returned: $RC"
            fi
        else
            check_warn "curl not available — skipping reachability probe"
        fi
    fi

    if [ -n "${ANTHROPIC_MODEL:-}" ]; then
        check_pass "ANTHROPIC_MODEL = $ANTHROPIC_MODEL"
    fi
    if [ -n "${ANTHROPIC_SMALL_FAST_MODEL:-}" ]; then
        check_pass "ANTHROPIC_SMALL_FAST_MODEL = $ANTHROPIC_SMALL_FAST_MODEL"
    fi

    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        check_pass "ANTHROPIC_API_KEY = $(redact_secret "$ANTHROPIC_API_KEY")"
    fi
    if [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
        check_pass "ANTHROPIC_AUTH_TOKEN = $(redact_secret "$ANTHROPIC_AUTH_TOKEN")"
    fi

    if [ -z "${ANTHROPIC_API_KEY:-}${ANTHROPIC_AUTH_TOKEN:-}" ] && [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
        check_warn "Custom base URL set but no ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN"
        check_hint "Most providers require a bearer token even for local proxies"
    fi

    check_hint "Recipes: see README → \"Using a custom model backend\""
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
