***THIS IS AN UNOFFICIAL BUILD SCRIPT!***

If you run into an issue with this build script, make an issue here. Don't bug Anthropic about it - they already have enough on their plates.

# Claude Desktop for Linux

Builds and installs Claude Desktop on Linux from the official Windows release, with full support for:

- **Cowork / Local Agent Mode** — runs Claude Code CLI directly (no VM required)
- **MCP** — `~/.config/Claude/claude_desktop_config.json`
- **Ctrl+Alt+Space** popup
- **System tray** (tray icons auto-inverted to white for dark Linux trays)
- **Wayland** — native Wayland via `--ozone-platform-hint=auto`
- **Bundled Claude Code CLI** — `claude` command available after install

![MCP support](https://github.com/user-attachments/assets/93080028-6f71-48bd-8e59-5149d148cd45)

![Ctrl+Alt+Space popup](https://github.com/user-attachments/assets/1deb4604-4c06-4e4b-b63f-7f6ef9ef28c1)

![Tray menu (KDE)](https://github.com/user-attachments/assets/ba209824-8afb-437c-a944-b53fd9ecd559)

---

## Supported Distros

| Family | Distros | Package |
|--------|---------|---------|
| RPM | Fedora, RHEL, CentOS, Rocky Linux, AlmaLinux | `.rpm` |
| DEB | Debian, Ubuntu, Linux Mint, Pop!_OS | `.deb` |
| Arch | Arch Linux, Manjaro, EndeavourOS | `.pkg.tar.zst` |

Pre-built packages are available on the [Releases](https://github.com/techtoboggan/claude-desktop-linux/releases) page.

## Requirements

- Node.js >= 18.0.0 and npm
- Root/sudo access

## Installation

### From GitHub Releases (recommended)

Download the latest package for your distro from [Releases](https://github.com/techtoboggan/claude-desktop-linux/releases), then:

```bash
# Fedora/RHEL
sudo dnf install claude-desktop-*.rpm

# Debian/Ubuntu
sudo dpkg -i claude-desktop_*.deb && sudo apt-get install -f

# Arch Linux
sudo pacman -U claude-desktop-*.pkg.tar.zst
```

### Build from source

```bash
git clone https://github.com/techtoboggan/claude-desktop-linux.git
cd claude-desktop-linux

# Auto-detects your distro and builds the right package
sudo ./build.sh

# Or specify explicitly:
# sudo FORMAT=rpm ./build.sh
# sudo FORMAT=deb ./build.sh
# sudo FORMAT=arch ./build.sh
```

The build script installs dependencies automatically via your package manager.

### Electron binary

The installed Claude Desktop uses your system Electron. If you hit GTK conflicts, install a standalone Electron:

```bash
cd /tmp
wget https://github.com/electron/electron/releases/download/v37.0.0/electron-v37.0.0-linux-x64.zip
sudo unzip electron-v37.0.0-linux-x64.zip -d /opt/electron
sudo chmod +x /opt/electron/electron

# Patch the launcher to use it
sudo tee /usr/bin/claude-desktop << 'EOF'
#!/bin/bash
LOG_FILE="$HOME/claude-desktop-launcher.log"
/opt/electron/electron /usr/lib64/claude-desktop/app.asar \
  --ozone-platform-hint=auto \
  --enable-logging=file --log-file=$LOG_FILE --log-level=INFO \
  --disable-gpu-sandbox --no-sandbox "$@"
EOF
sudo chmod +x /usr/bin/claude-desktop
```

---

## Version pinning

The `CLAUDE_VERSION` file pins the exact Claude release. To update:

1. Edit line 1 of `CLAUDE_VERSION` with the new version string
2. Optionally add the SHA256 of the nupkg on line 2 for verification
3. Commit and rebuild

---

## How it works

Claude Desktop ships as a Windows `.exe` installer containing an Electron app in an `.asar` archive. The build script:

1. Downloads the nupkg directly (or the Windows installer for unpinned builds)
2. Extracts the app and replaces platform-specific native modules with Linux stubs
3. Patches the app for Linux window decorations (CSD) and tray icons
4. Enables Cowork by patching the platform-gating code in the minified JS
5. Patches the Claude Code binary manager to find system-installed CLI on Linux
6. Injects startup code for menu bar removal and window icon
7. Bundles the Claude Code CLI
8. Packages as RPM, DEB, or Arch package

### Cowork on Linux

Instead of running a VM (as on macOS/Windows), Cowork on Linux spawns the Claude Code CLI directly with optional [bubblewrap](https://github.com/containers/bubblewrap) sandboxing. The stubs in `stubs/` implement the full IPC interface the app expects.

---

## Other distros

- **NixOS**: [k3d3/claude-desktop-linux-flake](https://github.com/k3d3/claude-desktop-linux-flake)

---

## License

Build scripts are dual-licensed under [MIT](LICENSE-MIT) and [Apache 2.0](LICENSE-APACHE).

The Claude Desktop application itself is covered by [Anthropic's Consumer Terms](https://www.anthropic.com/legal/consumer-terms).

## Contributions

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in the work by you, as defined in the Apache-2.0 license, shall be dual licensed as above, without any additional terms or conditions.
