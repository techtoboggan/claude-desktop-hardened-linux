#!/bin/bash
# RPM build-dependency installation (Fedora, RHEL, CentOS, Rocky, Alma)
#
# BASE CHANGE (2026-07): we repackage the OFFICIAL Linux .deb, so the build no
# longer needs 7z (nupkg), icoutils/ImageMagick (icon extraction), or a system
# electron/asar. We DO need dpkg-deb to unpack the official .deb, plus node/npm
# to bundle the Claude Code CLI.

install_deps() {
    echo "Checking build dependencies..."
    DEPS_TO_INSTALL=""

    for cmd in curl npx python3 rpmbuild dpkg-deb; do
        if ! check_command "$cmd"; then
            case "$cmd" in
                "curl")     DEPS_TO_INSTALL="$DEPS_TO_INSTALL curl" ;;
                "npx")      DEPS_TO_INSTALL="$DEPS_TO_INSTALL nodejs npm" ;;
                "python3")  DEPS_TO_INSTALL="$DEPS_TO_INSTALL python3" ;;
                "rpmbuild") DEPS_TO_INSTALL="$DEPS_TO_INSTALL rpm-build" ;;
                "dpkg-deb") DEPS_TO_INSTALL="$DEPS_TO_INSTALL dpkg" ;;
            esac
        fi
    done

    if [ -n "$DEPS_TO_INSTALL" ]; then
        echo "Installing system dependencies: $DEPS_TO_INSTALL"
        dnf install -y $DEPS_TO_INSTALL
        echo "System dependencies installed successfully"
    fi
}
