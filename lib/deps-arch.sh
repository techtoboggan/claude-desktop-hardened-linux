#!/bin/bash
# Arch Linux dependency installation

install_deps() {
    echo "Checking dependencies..."

    # base-devel is required for makepkg (provides fakeroot, binutils, etc.)
    echo "Installing base-devel group for makepkg..."
    pacman -S --noconfirm --needed base-devel

    DEPS_TO_INSTALL=""

    for cmd in 7z wget wrestool icotool convert npx python3 curl; do
        if ! check_command "$cmd"; then
            case "$cmd" in
                "7z")        DEPS_TO_INSTALL="$DEPS_TO_INSTALL p7zip" ;;
                "wget")      DEPS_TO_INSTALL="$DEPS_TO_INSTALL wget" ;;
                "wrestool"|"icotool") DEPS_TO_INSTALL="$DEPS_TO_INSTALL icoutils" ;;
                "convert")   DEPS_TO_INSTALL="$DEPS_TO_INSTALL imagemagick" ;;
                "npx")       DEPS_TO_INSTALL="$DEPS_TO_INSTALL nodejs npm" ;;
                "python3")   DEPS_TO_INSTALL="$DEPS_TO_INSTALL python" ;;
                "curl")      DEPS_TO_INSTALL="$DEPS_TO_INSTALL curl" ;;
            esac
        fi
    done

    if [ -n "$DEPS_TO_INSTALL" ]; then
        echo "Installing system dependencies: $DEPS_TO_INSTALL"
        pacman -S --noconfirm --needed $DEPS_TO_INSTALL
        echo "System dependencies installed successfully"
    fi

    # Install electron globally via npm if not present
    if ! check_command "electron"; then
        echo "Installing electron via npm..."
        npm install -g electron
        if ! check_command "electron"; then
            log_error "Failed to install electron. Please install it manually: sudo npm install -g electron"
            exit 1
        fi
    fi

    # Install asar if needed
    if ! command -v asar > /dev/null 2>&1; then
        echo "Installing asar package globally..."
        npm install -g asar
    fi
}
