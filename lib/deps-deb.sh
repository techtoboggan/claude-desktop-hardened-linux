#!/bin/bash
# DEB dependency installation (Debian, Ubuntu, Mint, Pop!_OS)

install_deps() {
    echo "Checking dependencies..."
    DEPS_TO_INSTALL=""

    for cmd in sqlite3 7z wget wrestool icotool convert npx python3 curl fakeroot; do
        if ! check_command "$cmd"; then
            case "$cmd" in
                "sqlite3")   DEPS_TO_INSTALL="$DEPS_TO_INSTALL sqlite3" ;;
                "7z")        DEPS_TO_INSTALL="$DEPS_TO_INSTALL p7zip-full" ;;
                "wget")      DEPS_TO_INSTALL="$DEPS_TO_INSTALL wget" ;;
                "wrestool"|"icotool") DEPS_TO_INSTALL="$DEPS_TO_INSTALL icoutils" ;;
                "convert")   DEPS_TO_INSTALL="$DEPS_TO_INSTALL imagemagick" ;;
                "npx")       DEPS_TO_INSTALL="$DEPS_TO_INSTALL nodejs npm" ;;
                "python3")   DEPS_TO_INSTALL="$DEPS_TO_INSTALL python3" ;;
                "curl")      DEPS_TO_INSTALL="$DEPS_TO_INSTALL curl" ;;
                "fakeroot")  DEPS_TO_INSTALL="$DEPS_TO_INSTALL fakeroot" ;;
            esac
        fi
    done

    if [ -n "$DEPS_TO_INSTALL" ]; then
        echo "Installing system dependencies: $DEPS_TO_INSTALL"
        apt-get update -qq
        apt-get install -y $DEPS_TO_INSTALL
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
