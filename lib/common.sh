#!/bin/bash
# Common utilities shared across the build pipeline.

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log_info()  { echo "  $*"; }
log_ok()    { echo "  ✓ $*"; }
log_warn()  { echo "  ⚠️  $*" >&2; }
log_error() { echo "  ❌ $*" >&2; }
log_step()  { echo "$1 $2"; }

# ---------------------------------------------------------------------------
# Version pinning
# ---------------------------------------------------------------------------

# Load pinned tool versions from TOOL_VERSIONS file.
read_tool_versions() {
    local tool_file="$SCRIPT_DIR/TOOL_VERSIONS"
    if [ -f "$tool_file" ]; then
        while IFS='=' read -r key value; do
            # Skip comments and empty lines
            [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
            key=$(echo "$key" | tr -d '[:space:]')
            value=$(echo "$value" | tr -d '[:space:]')
            export "$key=$value"
        done < "$tool_file"
        log_info "Loaded tool versions from TOOL_VERSIONS"
    else
        log_warn "TOOL_VERSIONS file not found — using defaults"
    fi
}

# Reads CLAUDE_VERSION file and sets CLAUDE_VERSION_PINNED + CLAUDE_DEB_SHA256.
# Also sets CLAUDE_DOWNLOAD_URL.
#
# BASE CHANGE (2026-07): we now build from the OFFICIAL Anthropic Claude Desktop
# Linux .deb (a native Linux build), NOT the Windows win32 nupkg. CLAUDE_VERSION
# line 1 = official .deb version, line 2 = that .deb's SHA256. The download URL
# points at Anthropic's official apt pool.
read_version_pin() {
    CLAUDE_VERSION_PINNED=""
    CLAUDE_DEB_SHA256=""
    if [ -f "$SCRIPT_DIR/CLAUDE_VERSION" ]; then
        CLAUDE_VERSION_PINNED=$(sed -n '1p' "$SCRIPT_DIR/CLAUDE_VERSION" | tr -d '[:space:]')
        CLAUDE_DEB_SHA256=$(sed -n '2p' "$SCRIPT_DIR/CLAUDE_VERSION" | tr -d '[:space:]')
    fi

    # Back-compat alias (some packaging templates still reference the old name).
    CLAUDE_NUPKG_SHA256="$CLAUDE_DEB_SHA256"

    local deb_arch
    deb_arch=$(arch_to_deb)
    CLAUDE_APT_BASE="https://downloads.claude.ai/claude-desktop/apt/stable"
    if [ -n "$CLAUDE_VERSION_PINNED" ]; then
        CLAUDE_DOWNLOAD_URL="${CLAUDE_APT_BASE}/pool/main/c/claude-desktop/claude-desktop_${CLAUDE_VERSION_PINNED}_${deb_arch}.deb"
    fi
}

# ---------------------------------------------------------------------------
# Command checking
# ---------------------------------------------------------------------------

check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo "  ❌ $1 not found"
        return 1
    else
        echo "  ✓ $1 found"
        return 0
    fi
}

# ---------------------------------------------------------------------------
# Sudo / user detection
# ---------------------------------------------------------------------------

detect_sudo_user() {
    IS_SUDO=false
    if [ "$EUID" -eq 0 ]; then
        IS_SUDO=true
        if [ -n "$SUDO_USER" ]; then
            ORIGINAL_USER="$SUDO_USER"
            ORIGINAL_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)
        else
            ORIGINAL_USER="root"
            ORIGINAL_HOME="/root"
        fi
    else
        echo "Please run with sudo to install dependencies"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# NVM path preservation (for sudo builds where Node is managed by NVM)
# ---------------------------------------------------------------------------

setup_nvm_path() {
    if [ "$IS_SUDO" = true ] && [ "$ORIGINAL_USER" != "root" ] && [ -d "$ORIGINAL_HOME/.nvm" ]; then
        echo "Found NVM installation for user $ORIGINAL_USER, attempting to preserve npm/npx path..."
        export NVM_DIR="$ORIGINAL_HOME/.nvm"
        [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

        NODE_BIN_PATH=$(find "$NVM_DIR/versions/node" -maxdepth 2 -type d -name 'bin' | sort -V | tail -n 1)
        if [ -n "$NODE_BIN_PATH" ] && [ -d "$NODE_BIN_PATH" ]; then
            echo "Adding $NODE_BIN_PATH to PATH"
            export PATH="$NODE_BIN_PATH:$PATH"
        else
            echo "Warning: Could not determine NVM Node bin path. npm/npx might not be found."
        fi
    fi
}

# ---------------------------------------------------------------------------
# System info
# ---------------------------------------------------------------------------

print_system_info() {
    echo "System Information:"
    echo "Distribution: $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)"
    [ -f /etc/fedora-release ] && echo "Distro: $(cat /etc/fedora-release)" \
        || echo "Distro: $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)"
}

# ---------------------------------------------------------------------------
# Format auto-detection
# ---------------------------------------------------------------------------

detect_format() {
    if [ -f /etc/arch-release ]; then
        echo "arch"
    elif [ -f /etc/debian_version ]; then
        echo "deb"
    elif [ -f /etc/fedora-release ] || [ -f /etc/redhat-release ]; then
        echo "rpm"
    elif command -v dpkg-deb &>/dev/null; then
        echo "deb"
    elif command -v rpmbuild &>/dev/null; then
        echo "rpm"
    elif command -v makepkg &>/dev/null; then
        echo "arch"
    else
        echo ""
    fi
}

# ---------------------------------------------------------------------------
# Architecture mapping
# ---------------------------------------------------------------------------

# Maps uname -m to DEB architecture names
arch_to_deb() {
    case "$(uname -m)" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l)  echo "armhf" ;;
        *)       echo "$(uname -m)" ;;
    esac
}

# ---------------------------------------------------------------------------
# Shared constants
# ---------------------------------------------------------------------------

PACKAGE_NAME="claude-desktop-hardened"
ARCHITECTURE=$(uname -m)
MAINTAINER="Claude Desktop Linux Maintainers"
DESCRIPTION="Claude Desktop for Linux (hardened)"
