#!/bin/bash
# Arch Linux build-dependency installation
#
# BASE CHANGE (2026-07): we repackage the OFFICIAL Linux .deb. We need dpkg
# (provides dpkg-deb) to unpack it, base-devel for makepkg, and node/npm to
# bundle the Claude Code CLI. No 7z/icoutils/electron/asar.

install_deps() {
    echo "Checking build dependencies..."

    # base-devel is required for makepkg (provides fakeroot, binutils, etc.)
    echo "Installing base-devel group for makepkg..."
    pacman -S --noconfirm --needed base-devel

    DEPS_TO_INSTALL=""
    for cmd in curl npx python3 dpkg-deb; do
        if ! check_command "$cmd"; then
            case "$cmd" in
                "curl")     DEPS_TO_INSTALL="$DEPS_TO_INSTALL curl" ;;
                "npx")      DEPS_TO_INSTALL="$DEPS_TO_INSTALL nodejs npm" ;;
                "python3")  DEPS_TO_INSTALL="$DEPS_TO_INSTALL python" ;;
                "dpkg-deb") DEPS_TO_INSTALL="$DEPS_TO_INSTALL dpkg" ;;
            esac
        fi
    done

    if [ -n "$DEPS_TO_INSTALL" ]; then
        echo "Installing system dependencies: $DEPS_TO_INSTALL"
        pacman -S --noconfirm --needed $DEPS_TO_INSTALL
        echo "System dependencies installed successfully"
    fi
}
