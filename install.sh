#!/usr/bin/env bash
# Claude Desktop (Hardened) for Linux — one-line installer
# Usage: curl -fsSL https://raw.githubusercontent.com/techtoboggan/claude-desktop-hardened-linux/main/install.sh | bash
#
# Detects your distro, downloads the latest release, and installs it.

set -euo pipefail

REPO="techtoboggan/claude-desktop-hardened-linux"
API="https://api.github.com/repos/${REPO}/releases/latest"

info()  { echo -e "\033[1;34m::\033[0m $*"; }
ok()    { echo -e "\033[1;32m✓\033[0m $*"; }
err()   { echo -e "\033[1;31m✗\033[0m $*" >&2; exit 1; }

# --- Detect distro family ---
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            fedora|rhel|centos|rocky|alma|nobara)  echo "rpm" ;;
            debian|ubuntu|pop|linuxmint|elementary) echo "deb" ;;
            arch|manjaro|endeavouros|garuda|cachyos) echo "arch" ;;
            opensuse*|sles)                         echo "rpm" ;;
            *)
                # Check ID_LIKE as fallback
                case "${ID_LIKE:-}" in
                    *fedora*|*rhel*)  echo "rpm" ;;
                    *debian*|*ubuntu*) echo "deb" ;;
                    *arch*)           echo "arch" ;;
                    *)                echo "unknown" ;;
                esac
                ;;
        esac
    else
        echo "unknown"
    fi
}

# --- Check for required tools ---
check_deps() {
    for cmd in curl; do
        command -v "$cmd" >/dev/null 2>&1 || err "Required command not found: $cmd"
    done
}

# --- Fetch latest release info ---
fetch_release() {
    info "Fetching latest release..."
    RELEASE_JSON=$(curl -fsSL "$API") || err "Failed to fetch release info from GitHub"
    TAG=$(echo "$RELEASE_JSON" | grep -oP '"tag_name"\s*:\s*"\K[^"]+')
    [ -n "$TAG" ] || err "Could not determine latest release tag"
    ok "Latest release: $TAG"
}

# --- Download and install ---
install_rpm() {
    local url
    url=$(echo "$RELEASE_JSON" | grep -oP '"browser_download_url"\s*:\s*"\K[^"]+\.rpm')
    [ -n "$url" ] || err "No RPM found in release $TAG"

    local tmp
    tmp=$(mktemp /tmp/claude-desktop-hardened-XXXXXX.rpm)
    info "Downloading RPM..."
    curl -fSL -o "$tmp" "$url" || err "Download failed"
    ok "Downloaded $(basename "$url")"

    info "Installing (requires sudo)..."
    if command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y "$tmp"
    elif command -v zypper >/dev/null 2>&1; then
        sudo zypper install -y --allow-unsigned-rpm "$tmp"
    elif command -v rpm >/dev/null 2>&1; then
        sudo rpm -Uvh "$tmp"
    else
        err "No supported package manager found (dnf/zypper/rpm)"
    fi
    rm -f "$tmp"
}

install_deb() {
    local url
    url=$(echo "$RELEASE_JSON" | grep -oP '"browser_download_url"\s*:\s*"\K[^"]+\.deb')
    [ -n "$url" ] || err "No DEB found in release $TAG"

    local tmp
    tmp=$(mktemp /tmp/claude-desktop-hardened-XXXXXX.deb)
    info "Downloading DEB..."
    curl -fSL -o "$tmp" "$url" || err "Download failed"
    ok "Downloaded $(basename "$url")"

    info "Installing (requires sudo)..."
    sudo dpkg -i "$tmp" || sudo apt-get install -f -y
    rm -f "$tmp"
}

install_arch() {
    local url
    url=$(echo "$RELEASE_JSON" | grep -oP '"browser_download_url"\s*:\s*"\K[^"]+PKGBUILD')
    [ -n "$url" ] || err "No PKGBUILD found in release $TAG"

    local tmpdir
    tmpdir=$(mktemp -d /tmp/claude-desktop-hardened-XXXXXX)
    info "Downloading PKGBUILD..."
    curl -fSL -o "$tmpdir/PKGBUILD" "$url" || err "Download failed"
    ok "Downloaded PKGBUILD"

    info "Building and installing with makepkg..."
    (cd "$tmpdir" && makepkg -si --noconfirm) || err "makepkg failed"
    rm -rf "$tmpdir"
}

# --- Main ---
main() {
    echo ""
    echo "  Claude Desktop (Hardened) for Linux — Installer"
    echo "  ────────────────────────────────────"
    echo ""

    check_deps

    DISTRO=$(detect_distro)
    info "Detected package format: $DISTRO"

    fetch_release

    case "$DISTRO" in
        rpm)  install_rpm ;;
        deb)  install_deb ;;
        arch) install_arch ;;
        *)    err "Unsupported distro. Download manually from: https://github.com/${REPO}/releases/latest" ;;
    esac

    echo ""
    ok "Claude Desktop (Hardened) installed! Launch it from your application menu or run: claude-desktop-hardened"
    echo ""
}

main "$@"
