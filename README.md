***THIS IS AN UNOFFICIAL BUILD SCRIPT!***

If you run into an issue with this build script, [make an issue here](https://github.com/techtoboggan/claude-desktop-linux/issues). Don't bug Anthropic about it — they already have enough on their plates.

# Claude Desktop for Linux

Builds and packages Claude Desktop for Linux from the official Windows release, with full support for:

- **Cowork / Local Agent Mode** — runs Claude Code CLI directly (no VM required)
- **MCP** — `~/.config/Claude/claude_desktop_config.json`
- **Ctrl+Alt+Space** quick entry popup
- **System tray** with auto-inverted icons for dark themes
- **Wayland** — native Wayland support via Ozone
- **Taskbar integration** — proper window grouping, pinning, and icons
- **Bundled Claude Code CLI** — `claude` command available system-wide after install

---

## Installation

### Quick install (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/techtoboggan/claude-desktop-linux/main/install.sh | bash
```

Detects your distro, downloads the latest release, and installs it.

### Fedora (COPR)

```bash
sudo dnf copr enable techtoboggan/claude-desktop
sudo dnf install claude-desktop
```

Updates automatically with `sudo dnf upgrade`.

### Manual install

Download the latest package for your distro from [Releases](https://github.com/techtoboggan/claude-desktop-linux/releases):

```bash
# Fedora / RHEL / Rocky
sudo dnf install claude-desktop-*.rpm

# Debian / Ubuntu
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

# Or specify a format explicitly
sudo FORMAT=rpm ./build.sh
sudo FORMAT=deb ./build.sh
sudo FORMAT=arch ./build.sh
```

Requires Node.js >= 18, npm, and root/sudo access. Dependencies are installed automatically.

---

## Supported distros

| Family | Distros | Package |
|--------|---------|---------|
| RPM | Fedora, RHEL, CentOS, Rocky, AlmaLinux, Nobara | `.rpm` |
| DEB | Debian, Ubuntu, Pop!_OS, Linux Mint | `.deb` |
| Arch | Arch Linux, Manjaro, EndeavourOS, CachyOS | `.pkg.tar.zst` |
| NixOS | [k3d3/claude-desktop-linux-flake](https://github.com/k3d3/claude-desktop-linux-flake) | Nix flake |

x86_64 only.

---

## How it works

Claude Desktop ships as a Windows `.exe` installer containing an Electron app packed in an `.asar` archive. The build script:

1. Downloads the pinned nupkg (version + SHA256 verified from `CLAUDE_VERSION`)
2. Extracts and patches the app.asar:
   - Replaces Windows/macOS native modules with Linux stubs
   - Patches platform-gating functions so Cowork activates on Linux
   - Patches the Claude Code binary manager to find the system-installed CLI
   - Injects startup code for menu bar removal, window icons, and tray fixes
   - Patches window decorations for Linux client-side decorations (CSD)
   - Inverts tray icons to white for dark system trays
3. Bundles the Claude Code CLI
4. Packages everything as RPM, DEB, or Arch package

### Cowork on Linux

On macOS/Windows, Cowork runs inside a VM. On Linux, it spawns the Claude Code CLI directly. The stubs in `stubs/cowork/` implement the IPC interface the desktop app expects for session management, file watching, and credential handling.

---

## Version pinning

`CLAUDE_VERSION` pins the exact Claude Desktop release:

- **Line 1**: version string (e.g., `1.1.9134`)
- **Line 2**: SHA256 of the nupkg for supply chain verification

To update: change line 1, optionally update the hash, commit and push to `main`. The release workflow builds, tags, and publishes automatically.

---

## License

Build scripts and stubs are dual-licensed under [MIT](LICENSE-MIT) and [Apache 2.0](LICENSE-APACHE).

The Claude Desktop application itself is covered by [Anthropic's Consumer Terms](https://www.anthropic.com/legal/consumer-terms).
