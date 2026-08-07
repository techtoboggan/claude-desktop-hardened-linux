#!/bin/bash
# Arch Linux build-dependency installation
#
# BASE CHANGE (2026-07): we repackage the OFFICIAL Linux .deb. We need dpkg
# (provides dpkg-deb) to unpack it, base-devel for makepkg, and node/npm to
# bundle the Claude Code CLI. No 7z/icoutils/electron/asar.

install_deps() {
    echo "Checking build dependencies..."

    # Arch is rolling, and this build runs inside a PINNED (older) base image.
    # Installing current packages onto a stale image is a "partial upgrade",
    # which Arch does not support: a freshly-installed Node binary is linked
    # against the current glibc and won't execute on the old image's glibc
    # (build-arch failed with node/npm present-but-unrunnable). Do a FULL
    # system upgrade first so glibc + toolchain are consistent, THEN install.
    # base-devel is required for makepkg (fakeroot, binutils, etc.).
    echo "Full system upgrade + base-devel (avoids partial-upgrade breakage)..."
    pacman -Syu --noconfirm --needed base-devel

    DEPS_TO_INSTALL=""
    for cmd in curl npx python3 dpkg-deb; do
        if ! check_command "$cmd"; then
            case "$cmd" in
                "curl")     DEPS_TO_INSTALL="$DEPS_TO_INSTALL curl" ;;
                # Pin to the LTS Node (nodejs-lts-jod = 22.x), NOT the rolling
                # `nodejs` package. Arch rolled `nodejs` to 26.x / `npm` to 12.x
                # around 2026-08, which broke `npm install` of the bundled Claude
                # Code CLI (build-arch failed while Fedora/Ubuntu, on older Node,
                # passed). LTS keeps the build toolchain stable across Arch rolls.
                "npx")      DEPS_TO_INSTALL="$DEPS_TO_INSTALL nodejs-lts-jod npm" ;;
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
