#!/bin/bash
# DEB build-dependency installation (Debian, Ubuntu, Mint, Pop!_OS)
#
# BASE CHANGE (2026-07): we repackage the OFFICIAL Linux .deb. dpkg-deb ships
# with dpkg (always present on Debian/Ubuntu). No 7z/icoutils/electron/asar.

install_deps() {
    echo "Checking build dependencies..."
    DEPS_TO_INSTALL=""

    for cmd in curl npx python3 fakeroot dpkg-deb; do
        if ! check_command "$cmd"; then
            case "$cmd" in
                "curl")     DEPS_TO_INSTALL="$DEPS_TO_INSTALL curl" ;;
                "npx")      DEPS_TO_INSTALL="$DEPS_TO_INSTALL nodejs npm" ;;
                "python3")  DEPS_TO_INSTALL="$DEPS_TO_INSTALL python3" ;;
                "fakeroot") DEPS_TO_INSTALL="$DEPS_TO_INSTALL fakeroot" ;;
                "dpkg-deb") DEPS_TO_INSTALL="$DEPS_TO_INSTALL dpkg" ;;
            esac
        fi
    done

    if [ -n "$DEPS_TO_INSTALL" ]; then
        echo "Installing system dependencies: $DEPS_TO_INSTALL"
        apt-get update -qq
        apt-get install -y $DEPS_TO_INSTALL
        echo "System dependencies installed successfully"
    fi
}
