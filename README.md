***This is an unofficial, community-maintained project. It is not affiliated with or endorsed by Anthropic.***

This project repackages the official Claude Desktop release for Linux with additional security hardening (bubblewrap sandboxing, credential redaction, permission-gated Computer Use). Anthropic does not provide support for this build — if you run into an issue, [open an issue on our tracker](https://github.com/techtoboggan/claude-desktop-hardened-linux/issues), not Anthropic's.

# Claude Desktop for Linux (Hardened)

A security-focused Linux build of Claude Desktop. Downloads the official release, applies bubblewrap sandboxing, credential redaction, and permission-gated Computer Use — then packages it for Fedora, Debian/Ubuntu, and Arch Linux.

## Features

- **Cowork / Local Agent Mode** — sandboxed via [bubblewrap](https://github.com/containers/bubblewrap) with default-deny filesystem, resource limits, credential redaction, and environment allowlisting
- **Computer Use** — screenshot, click, type, and scroll automation for both X11 and Wayland, gated by a per-session permission dialog (no auto-grant)
- **MCP** (Model Context Protocol) — configure servers in `~/.config/Claude/claude_desktop_config.json`
- **Ctrl+Alt+Space** quick entry popup
- **System tray** with auto-inverted icons for dark themes
- **Native Wayland support** — auto-detected, with proper taskbar pinning, window grouping, and Ozone platform hints
- **Bundled Claude Code CLI** — `claude` command available system-wide after install
- **Diagnostic tool** — `claude-desktop-hardened --doctor` checks your system for missing dependencies and misconfigurations

---

## Installation

### Fedora (COPR)

Available from [Fedora COPR](https://copr.fedorainfracloud.org/coprs/techtoboggan/claude-desktop-hardened/) for Fedora 43 and 44:

```bash
sudo dnf copr enable techtoboggan/claude-desktop-hardened
sudo dnf install claude-desktop-hardened
```

Updates automatically with `sudo dnf upgrade`.

### Arch Linux (AUR)

```bash
yay -S claude-desktop-hardened-bin
```

Or manually:

```bash
git clone https://aur.archlinux.org/claude-desktop-hardened-bin.git
cd claude-desktop-hardened-bin
makepkg -si
```

### Debian / Ubuntu (APT)

```bash
curl -fsSL https://techtoboggan.github.io/claude-desktop-hardened-linux/pubkey.asc | sudo gpg --dearmor -o /usr/share/keyrings/claude-desktop-hardened.gpg
echo "deb [signed-by=/usr/share/keyrings/claude-desktop-hardened.gpg] https://techtoboggan.github.io/claude-desktop-hardened-linux stable main" | sudo tee /etc/apt/sources.list.d/claude-desktop-hardened.list
sudo apt update
sudo apt install claude-desktop-hardened
```

### Quick install (any distro)

```bash
curl -fsSL https://raw.githubusercontent.com/techtoboggan/claude-desktop-hardened-linux/main/install.sh | bash
```

Detects your distro, downloads the latest release from GitHub, verifies SHA256 checksums, and installs it.

### Manual install

Download the latest package from [Releases](https://github.com/techtoboggan/claude-desktop-hardened-linux/releases):

```bash
# Fedora / RHEL / Rocky
sudo dnf install claude-desktop-hardened-*.rpm

# Debian / Ubuntu
sudo dpkg -i claude-desktop-hardened_*.deb && sudo apt-get install -f

# Arch Linux
sudo pacman -U claude-desktop-hardened-*.pkg.tar.zst
```

### Build from source

```bash
git clone https://github.com/techtoboggan/claude-desktop-hardened-linux.git
cd claude-desktop-hardened-linux

# Auto-detects your distro and builds the right package
sudo ./build.sh

# Or specify a format explicitly
sudo FORMAT=rpm ./build.sh
sudo FORMAT=deb ./build.sh
sudo FORMAT=arch ./build.sh
```

Requires Node.js 18-23, npm, and root/sudo access. Build dependencies are installed automatically.

---

## Supported distros

| Family | Distros | Package | Repo |
|--------|---------|---------|------|
| RPM | Fedora 43/44 | `.rpm` | [COPR](https://copr.fedorainfracloud.org/coprs/techtoboggan/claude-desktop-hardened/) |
| RPM | RHEL, CentOS, Rocky, AlmaLinux, Nobara | `.rpm` | [GitHub Releases](https://github.com/techtoboggan/claude-desktop-hardened-linux/releases) |
| DEB | Debian, Ubuntu, Pop!_OS, Linux Mint | `.deb` | [APT repo](https://techtoboggan.github.io/claude-desktop-hardened-linux) |
| Arch | Arch Linux, Manjaro, EndeavourOS, CachyOS | `.pkg.tar.zst` | [AUR](https://aur.archlinux.org/packages/claude-desktop-hardened-bin) |

x86_64 only.

---

## Post-install

### Verify your setup

```bash
claude-desktop-hardened --doctor
```

Checks Electron, chrome-sandbox permissions, bubblewrap, display server, Computer Use tools, MCP config, Claude Code CLI, Node.js, and keyring availability.

### Computer Use tools (optional)

Install the tools for your display server to enable Computer Use:

**Wayland** (GNOME, KDE Plasma, Sway, Hyprland):
```bash
# Fedora
sudo dnf install grim slurp wl-clipboard ydotool wlr-randr

# Debian / Ubuntu
sudo apt install grim slurp wl-clipboard ydotool wlr-randr

# Arch
sudo pacman -S grim slurp wl-clipboard ydotool wlr-randr
```

**X11**:
```bash
# Fedora
sudo dnf install wmctrl xdotool scrot xclip xrandr

# Debian / Ubuntu
sudo apt install wmctrl xdotool scrot xclip x11-xserver-utils

# Arch
sudo pacman -S wmctrl xdotool scrot xclip xorg-xrandr
```

### Keyboard shortcuts on Wayland

Wayland does not allow applications to register global keyboard shortcuts (like Ctrl+Alt+Space) — this is a security feature of the protocol. The launcher enables the `GlobalShortcutsPortal` Electron feature flag, which works on **KDE Plasma** and **Hyprland** (users assign the key in system settings).

For compositors without portal support (GNOME, Sway), bind a shortcut manually:

```bash
# Hyprland (~/.config/hypr/hyprland.conf)
bind = CTRL ALT, Space, exec, claude-desktop-hardened --focus

# Sway (~/.config/sway/config)
bindsym Ctrl+Alt+Space exec claude-desktop-hardened --focus

# i3 (~/.config/i3/config)
bindsym Ctrl+Alt+space exec claude-desktop-hardened --focus
```

Run `claude-desktop-hardened --doctor` to check if your compositor supports the GlobalShortcuts portal.

### MCP servers

Configure MCP servers in `~/.config/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "example": {
      "command": "node",
      "args": ["/path/to/server.js"]
    }
  }
}
```

---

## Using a custom model backend

Point Code / Cowork sessions at your own model backend — a local LLM via **LM Studio** or **Ollama**, a routing proxy like **LiteLLM** or **OpenRouter**, or a self-hosted **vLLM** server — instead of Anthropic's default endpoint.

> **Scope:** this override applies to **Code / Cowork (agent) mode only**. Conversation mode keeps using `claude.ai` because that UI is a hosted web app, not something we can redirect to a different frontend.

### Two ways to configure

**1. CLI flags (quickest for trying it out):**

```bash
claude-desktop-hardened --model claude-sonnet-4-5-20250929 \
                       --base-url http://localhost:4000
```

Flags are consumed by the launcher and forwarded as env vars to the Code CLI. They don't get passed to Electron.

**2. Shell env vars (persistent — put in `~/.bashrc`, `~/.zshrc`, or `~/.config/fish/config.fish`):**

```bash
export ANTHROPIC_BASE_URL=http://localhost:4000
export ANTHROPIC_AUTH_TOKEN=sk-your-backend-key
export ANTHROPIC_MODEL=claude-sonnet-4-5-20250929
```

Env vars are the recommended path for daily use. Secrets (API keys, auth tokens) are deliberately **not** accepted as CLI flags — they'd leak into `ps aux` and shell history.

### Provider recipes

Each block shows the env var form. Swap `export FOO=bar` for `claude-desktop-hardened --foo bar` equivalents as needed.

**LiteLLM proxy** — the most common multi-provider setup:

```bash
# Terminal 1: start the proxy
pip install litellm
litellm --port 4000 --model claude-sonnet-4-5-20250929

# Terminal 2: point the app at it
export ANTHROPIC_BASE_URL=http://localhost:4000
export ANTHROPIC_AUTH_TOKEN=sk-your-litellm-key
export ANTHROPIC_MODEL=claude-sonnet-4-5-20250929
claude-desktop-hardened
```

**LM Studio** — local GUI LLM server:

```bash
# In LM Studio: load a model, start the server (default port 1234).
export ANTHROPIC_BASE_URL=http://localhost:1234/v1
export ANTHROPIC_AUTH_TOKEN=lm-studio
export ANTHROPIC_MODEL=<your-loaded-model-id>
claude-desktop-hardened
```

**Ollama** — via LiteLLM passthrough (Ollama's native API isn't Anthropic-compatible, so proxy through LiteLLM):

```bash
# ~/litellm.config.yaml
# model_list:
#   - model_name: llama3.1:70b
#     litellm_params:
#       model: ollama/llama3.1:70b
#       api_base: http://localhost:11434

litellm --config ~/litellm.config.yaml --port 4000 &
export ANTHROPIC_BASE_URL=http://localhost:4000
export ANTHROPIC_MODEL=llama3.1:70b
claude-desktop-hardened
```

**OpenRouter** — hosted multi-provider routing:

```bash
export ANTHROPIC_BASE_URL=https://openrouter.ai/api/v1
export ANTHROPIC_AUTH_TOKEN=sk-or-v1-...
export ANTHROPIC_MODEL=anthropic/claude-sonnet-4.5
claude-desktop-hardened
```

**vLLM** — self-hosted inference server:

```bash
# Start vLLM with Anthropic-compatible endpoints enabled:
vllm serve <your-model> --host 0.0.0.0 --port 8000

export ANTHROPIC_BASE_URL=http://localhost:8000
export ANTHROPIC_MODEL=<your-model>
claude-desktop-hardened
```

**Anthropic direct (BYOK)** — use your own Anthropic key instead of OAuth:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
# (no ANTHROPIC_BASE_URL needed — uses Anthropic's default)
claude-desktop-hardened
```

### Environment variable reference

| Variable | Purpose | Example |
|---|---|---|
| `ANTHROPIC_BASE_URL` | Override backend URL | `http://localhost:4000` |
| `ANTHROPIC_AUTH_TOKEN` | Bearer token for the backend | `sk-litellm-…` |
| `ANTHROPIC_API_KEY` | Anthropic-style API key | `sk-ant-…` |
| `ANTHROPIC_MODEL` | Default model | `claude-sonnet-4-5-20250929` |
| `ANTHROPIC_SMALL_FAST_MODEL` | Quick/cheap model for summaries | `claude-haiku-4-5` |
| `ANTHROPIC_DEFAULT_OPUS_MODEL` | Per-tier override (when UI picks Opus) | `gpt-4o` |
| `ANTHROPIC_DEFAULT_SONNET_MODEL` | Per-tier override (when UI picks Sonnet) | `gpt-4o-mini` |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL` | Per-tier override (when UI picks Haiku) | `llama3.1:8b` |
| `ANTHROPIC_CUSTOM_HEADERS` | Extra HTTP headers sent with every request | `X-Project: foo` |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS` | Per-request output token cap | `8192` |

### Verify

```bash
claude-desktop-hardened --doctor
```

If any `ANTHROPIC_*` env var is set, `--doctor` shows a **Custom Model Backend** section with the resolved values (secrets redacted) and probes `ANTHROPIC_BASE_URL` for reachability. A `401` or `404` from the probe is still `[OK]` — it proves the socket is up and TLS worked, which is what the check is actually testing.

### Troubleshooting

- **"My CLI flag is ignored"** — make sure `--model` and `--base-url` come *before* any `--` separator or free args. Order: `claude-desktop-hardened --model X --base-url Y`.
- **"Cowork session hangs on connect"** — run `--doctor`, confirm reachability. Check firewalls and whether your backend is listening on `0.0.0.0` (not just `127.0.0.1` if you're using a container).
- **"TLS error"** — local proxies with self-signed certs will fail. Use plain `http://` for loopback, or install the self-signed cert into your system CA store.
- **"Model name rejected"** — provider model-name formats differ: OpenRouter uses `vendor/model`, Ollama uses `name:tag`, LM Studio wants the exact loaded model's ID string from its server UI.

### Bedrock / Vertex / extra env vars (advanced)

AWS Bedrock and Google Vertex aren't default-enabled because their required env vars (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `GOOGLE_APPLICATION_CREDENTIALS`, `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX`) are cloud credentials with broader scope than just the model backend — we don't want them silently leaking into the sandbox unless you've explicitly said you want them there.

To opt in, edit the allowlist in `/usr/lib64/claude-desktop-hardened/stubs/claude-swift-stub/index.js` (or `/usr/lib/claude-desktop-hardened/...` on Debian). Add the vars you need to the `ENV_ALLOWLIST` Set. **Note:** the edit is reverted on package upgrade; for reproducibility, keep a post-install hook that re-applies your override, or open an issue if you'd like first-class support.

---

## Security model

This project treats Claude's agentic capabilities as a security boundary. Every feature that touches the host system is sandboxed, logged, or gated behind user confirmation.

### Cowork sandboxing

When Cowork spawns a Claude Code session, it runs inside a [bubblewrap](https://github.com/containers/bubblewrap) sandbox with a default-deny filesystem policy:

- **Minimal rootfs** — only `/usr`, `/lib`, `/lib64`, and select `/etc` files are mounted read-only. The agent cannot see your home directory, browser data, password managers, or other users' files.
- **Writable mounts** limited to the working directory, session data, and `~/.config/Claude`
- **Resource limits** via `systemd-run` — 4GB memory, 200% CPU (2 cores), 512 max tasks to prevent runaway processes and fork bombs
- **`--die-with-parent`** ensures cleanup if the parent process exits
- **Environment allowlisting** — only safe variables pass through (HOME, PATH, DISPLAY, XDG_*, plus standard `ANTHROPIC_*` SDK vars for [custom backends](#using-a-custom-model-backend)). Cloud credentials (`AWS_*`, `GOOGLE_*`) are deliberately excluded.
- **No unsandboxed fallback** — if bubblewrap is not found, sessions refuse to start

Bubblewrap is a **hard dependency** — if you're using this package, you get sandboxing. That's the point.

### Network access

Sandboxed sessions have **full network access**. Claude Code needs HTTPS to `api.anthropic.com` to function, and isolating the network would break core functionality. This means the agent can theoretically reach internal services on your network. If you run services on localhost or your LAN that accept unauthenticated requests, be aware of this. We may add network policy support (via nftables or a proxy) in a future release.

### Computer Use permissions

Every Computer Use permission request shows a native dialog — nothing is auto-granted:

- **Screen Recording** — screenshot capture via `grim` (Wayland) or `scrot` (X11)
- **Input Automation** — click/type/scroll via `ydotool` (Wayland) or `xdotool` (X11)
- **Window Listing** — via `hyprctl`/`swaymsg` (Wayland) or `wmctrl` (X11)

Grants are session-only — they reset when you close Claude Desktop. All Computer Use actions are logged to the transcript store with credential redaction applied.

### Credential redaction

All session transcripts are scrubbed before hitting disk:

- Bearer tokens, API keys (AWS, GitHub, Anthropic, OpenAI, Slack, Stripe, npm, PyPI)
- JWTs, OAuth tokens, private keys, database connection strings
- Google Cloud service account key IDs
- Generic secrets in environment-style assignments
- Sensitive environment variables filtered from subprocess environments

### Path safety

File operations are checked against a blocklist that includes sensitive directories (`.ssh`, `.gnupg`, `.aws`, `.kube`, `.docker`) and persistence vectors (`.bashrc`, `.profile`, `.config/autostart`, `cron`). Path traversal (`..`) is blocked at the raw input level before normalization.

### Electron sandbox

The `chrome-sandbox` binary is set to `4755 root:root` (setuid) during post-install. This preserves Electron's multi-process sandbox — the renderer runs in a restricted namespace even if the main process is compromised.

---

## Supply chain integrity

### Version pinning

Two files control all external dependency versions:

- **`CLAUDE_VERSION`** — pins the exact Claude Desktop release (version + SHA256 of the nupkg)
- **`TOOL_VERSIONS`** — pins Electron, asar, cdxgen, Claude CLI, vet, and container image digests

All GitHub Actions are pinned to full commit SHAs. Container images are pinned to SHA256 digests. npm packages are installed with `--ignore-scripts`.

### CI pipeline

Every push and PR runs:

- **Unit tests** — credential classifier (19 tests), path safety (9 tests), patch system (19 tests), doctor integration (7 tests)
- **Package smoke tests** — verifies each built package contains expected files, correct permissions, valid desktop entry, and reasonable size
- **Source integrity** — trojan source / Unicode attack scanning on all JS, shell, and Python files
- **Dependency scanning** — OWASP depscan for vulnerabilities, vet for malware
- **Post-patch validation** — `node --check` verifies patched JS is syntactically valid
- **SBOM** — CycloneDX bill of materials attached to every release

### Automated updates

A CI workflow checks for new Claude Desktop releases daily. When a new version is found, it:

1. Downloads the new nupkg and computes its SHA256
2. Test-builds an RPM in a Fedora container to verify patches apply cleanly
3. Validates the patched JS with `node --check`
4. If everything passes, pushes the version bump to `main` (which triggers the release pipeline)
5. If the build fails, opens a GitHub issue with diagnostics and the build log

### Release pipeline

When `CLAUDE_VERSION` changes on `main`, the release workflow:

1. Builds RPM, DEB, and Arch packages in pinned containers
2. Generates a CycloneDX SBOM
3. Creates a GitHub Release with SHA256SUMS (GPG-signed if key is configured)
4. Publishes to Fedora COPR, GitHub Pages APT repo, and AUR automatically

---

## Configuration reference

These optional config files let you customize Cowork behavior. All paths follow the [XDG Base Directory Specification](https://specifications.freedesktop.org/basedir-spec/latest/) — if `XDG_CONFIG_HOME` is set, it replaces `~/.config`.

### Resource limits (`~/.config/Claude/cowork-limits.json`)

Override the default systemd-run resource limits for sandboxed Cowork sessions:

```json
{
  "memoryMax": "8G",
  "cpuQuota": "400%",
  "tasksMax": "1024"
}
```

| Key | Default | Description |
|-----|---------|-------------|
| `memoryMax` | `4G` | Maximum memory (systemd format: `4G`, `512M`, etc.) |
| `cpuQuota` | `200%` | CPU quota — `200%` means 2 cores |
| `tasksMax` | `512` | Maximum number of processes/threads |

Values must match the pattern `^\d+[GMKT%]?$`. Invalid entries are silently ignored and defaults are used.

### Custom credential patterns (`~/.config/Claude/credential-patterns.json`)

Add your own regex patterns for credential redaction on top of the built-in set:

```json
{
  "patterns": [
    "my-internal-token-[A-Za-z0-9]{32}",
    "CORP_SECRET_[A-Z0-9]+"
  ]
}
```

Each pattern is compiled as a case-sensitive regex. Patterns longer than 500 characters are skipped. Malformed regexes are logged and ignored.

### Debug logging (`COWORK_DEBUG` environment variable)

Enable verbose debug logging for all Cowork subsystems (session orchestrator, Computer Use, credential classifier):

```bash
COWORK_DEBUG=1 claude-desktop-hardened
```

Debug output is prefixed with `[cowork-debug]` and written to stderr. Useful for diagnosing sandbox startup failures, tool resolution issues, or Computer Use problems.

### Transcript and session logs

Cowork session transcripts (with credential redaction applied) are stored at:

```
~/.local/state/claude-cowork/logs/
```

These contain a log of all Computer Use actions, session lifecycle events, and redacted command output. Transcripts are retained until manually deleted.

---

## How it works

Claude Desktop ships as a Windows `.exe` installer containing an Electron app. The build script:

1. **Downloads** the pinned nupkg (version + SHA256 verified from `CLAUDE_VERSION`)
2. **Extracts icons** from the Windows exe (16px through 256px)
3. **Replaces native modules** — swaps Windows/macOS native addons with Linux stubs for keyboard constants, platform detection, and Cowork session management
4. **Installs Cowork stubs** — a process orchestrator for spawning sandboxed Claude Code CLI sessions with credential redaction, file watching, session persistence, and IPC handling
5. **Installs Computer Use modules** — display-server-aware screenshot, window listing, and input automation with a permission dialog layer
6. **Patches platform gating** — modular patches in `patches/` surgically modify 8 locations in the minified JS to accept Linux as a supported platform
7. **Patches window decorations** — switches from macOS `hiddenInset` to Electron CSD with transparent title bar overlay
8. **Injects startup code** — sets the window icon, fixes the system tray, sets Wayland `app_id`, and registers permission-gated Computer Use handlers
9. **Inverts tray icons** for dark Linux system trays
10. **Bundles Claude Code CLI** from npm (pinned version, `--ignore-scripts`)
11. **Packages** as RPM, DEB, or Arch with post-install hooks for icon caches, desktop database updates, and chrome-sandbox setuid

### Patch architecture

Platform patches are modular — each lives in its own file under `patches/`:

| Patch | Purpose |
|-------|---------|
| `patch_platform_gating.py` | Accept Linux in platform check functions |
| `patch_vm_manifest.py` | Add Linux entries to VM image manifest |
| `patch_platform_constants.py` | Include Linux in `isSupportedPlatform` |
| `patch_enterprise_config.py` | Ensure VM features aren't forced off |
| `patch_api_headers.py` | Spoof platform headers for feature checks |
| `patch_binary_manager.py` | Add Linux to `getHostPlatform()` |
| `patch_binary_resolution.py` | Find system-installed Claude CLI |
| `inject_cowork_init.py` | Wire up Cowork lifecycle hooks |

This makes version bumps easier — when upstream renames minified symbols, you update one file instead of a monolithic script.

### Package metadata

All packaging specs (RPM, DEB, Arch, COPR repackage) are generated from a single source of truth:

```bash
python3 packaging/generate-specs.py
```

This reads `packaging/metadata.json` and outputs all four spec files, ensuring dependencies, file lists, and descriptions never drift.

---

## License

Build scripts and stubs are dual-licensed under [MIT](LICENSE-MIT) and [Apache 2.0](LICENSE-APACHE).

The Claude Desktop application itself is covered by [Anthropic's Consumer Terms](https://www.anthropic.com/legal/consumer-terms).
