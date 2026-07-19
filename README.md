***This is an unofficial, community-maintained project. It is not affiliated with or endorsed by Anthropic.***

This project repackages **Anthropic's official Claude Desktop Linux build** (`.deb`) with a security-hardening layer — **enforced [bubblewrap](https://github.com/containers/bubblewrap) sandboxing** plus supply-chain hardening — and ships it for **Fedora/RHEL and Arch** (which the official build doesn't cover), as well as a hardened `.deb`. Anthropic does not support this build — [open an issue on our tracker](https://github.com/techtoboggan/claude-desktop-hardened-linux/issues), not Anthropic's.

# Claude Desktop for Linux (Hardened)

The official Anthropic Claude Desktop Linux app, **wrapped in a bubblewrap sandbox** and repackaged for more distros. The application payload is Anthropic's official Linux build, **unmodified** — we don't patch `app.asar` or inject code. Our contribution is the security wrapper and the packaging.

> **Base change (July 2026):** Anthropic now publishes an official Claude Desktop Linux `.deb`. This project switched from porting the Windows build to **repackaging that official Linux build**. See [How it works](#how-it-works).

## What we add

- **Enforced sandboxing** — the app runs inside a [bubblewrap](https://github.com/containers/bubblewrap) namespace: read-only system, device access limited to GPU/KVM/sound, and PID/UTS/cgroup isolation. Because Claude is agentic (Cowork/Code sessions and MCP servers need your files and tools), `$HOME` is **default-allow but with credential/secret locations masked** — `~/.ssh`, `~/.gnupg`, cloud creds (`~/.aws`, `~/.config/gcloud`, `~/.kube`, …), browser profiles, and keyrings are replaced with empty tmpfs, so a compromised renderer or MCP server can't read your secrets or modify the system, while your projects still work. Escape hatch: `CLAUDE_NO_SANDBOX=1`.
- **Fedora/RHEL + Arch packaging** — the official build is Debian/Ubuntu-only; we cover the RPM and Arch worlds (plus a hardened `.deb`).
- **Supply-chain hardening** — the official `.deb` is pinned by SHA256, releases ship an SBOM (CycloneDX) and GPG-signed `SHA256SUMS`, all CI actions are SHA-pinned, and sources are scanned for trojan-source/malware.
- **Bundled Claude Code CLI** — the `claude` command, available system-wide after install.
- **Diagnostics** — `claude-desktop-hardened --doctor`.

Everything the app itself does (Chat, Cowork, Code, MCP, Wayland support, tray) comes from Anthropic's official build. Features that were previously *injected* by this project when it ported the Windows build (in-app custom-backend chip, our own Computer Use permission UI, credential-redaction stubs) were **removed** in the July 2026 rebase — the official Linux app provides its own implementations.

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

### Backend toggle in the title bar

There's a segmented chip in the top-left of the title bar (right next to the Claude icon) showing both backend options side-by-side. The active one is highlighted, the other is faded:

```
[ Anthropic | qwen35-4bit ]
```

- 🟢 **green** pill = local backend active
- 🟡 **amber** pill = Anthropic (default) active
- ⚫ **dim "Local (not set)"** = no local backend configured yet

**Hover** for a native tooltip with the full URL, model, and source (shell env vs config file). **Click** either pill to switch — the new backend applies to the **next Code session you start**. Currently-running sessions keep their original env vars (we don't swap mid-conversation).

**Real-time refresh:** changes from `--use-local` / `--toggle-backend` / direct JSON edits to `~/.config/Claude/custom-backend.json` update the chip in the running app immediately (we `fs.watch` the file).

### Third-Party Inference setup (conversation mode too!) 🎉

Recent Claude Desktop builds ship a **hidden third-party model provider setup window** — full OAuth + MCP integration that affects both conversation and Code modes. It's gated in the upstream Help menu behind a dev settings flag, but **our title bar chip bypasses the gate**: click the dim "Local (not set)" pill, or right-click either pill, to open the setup window directly.

The setup window (900×720) is Anthropic's own UI for configuring custom inference providers. It handles:

- **OAuth flow** for providers that require it (with HTTPS enforcement and encrypted token storage)
- **Enterprise config** schema for BYOK deployments
- **Custom HTTP headers** per provider
- **MCP-based integration** so the app's normal tool + model pipeline routes through your provider

This is **Anthropic-authored infrastructure** — no reverse engineering, just flipping a flag they already built. Unlike our env-var-only override (which only affects Code mode), configuring a provider here makes **conversation mode use your backend too**.

> ⚠️ This is a hidden feature that Anthropic hasn't officially launched. No TODOs or "experimental" gates in the code, but treat it as unofficial: Anthropic could change the setup flow, config format, or remove the feature in a future release.

**Alternative access paths:**

```bash
# Unlock the upstream menu item (Help → Configure Third-Party Inference…).
# Requires app restart. Not needed if you use the chip — just a convenience
# if you prefer the menu.
claude-desktop-hardened --enable-third-party-setup
```

Or edit `~/.config/Claude/developer_settings.json` directly:

```json
{ "allowDevTools": true }
```

### Two ways to configure

**1. CLI flags (quickest for trying it out):**

```bash
claude-desktop-hardened --model claude-sonnet-4-5-20250929 \
                       --base-url http://localhost:4000
```

Flags are consumed by the launcher and forwarded as env vars to the Code CLI. They don't get passed to Electron.

> **Tier mapping:** The `--model` flag also sets `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL` and `ANTHROPIC_SMALL_FAST_MODEL` to the same value (unless you've explicitly set those env vars first). This is required because the UI's model picker spawns the CLI with `--model sonnet` (etc.), which would otherwise override your `ANTHROPIC_MODEL`. With tier aliasing, whichever tier you click in the UI resolves to your chosen backend model.

> **Persistence:** `--model` and `--base-url` also write to `~/.config/Claude/custom-backend.json` so the title bar toggle remembers them. Run once with the flags, then toggle on/off from the UI going forward without needing the flags again.

**Keyboard-shortcut-friendly CLI flags:**

```bash
claude-desktop-hardened --toggle-backend   # flip on/off (binds nicely to a shortcut)
claude-desktop-hardened --use-local        # force local backend on
claude-desktop-hardened --use-anthropic    # force Anthropic backend
```

These exit immediately after updating the config, so you can bind them in your WM / DE:

```bash
# Hyprland (~/.config/hypr/hyprland.conf)
bind = SUPER SHIFT, L, exec, claude-desktop-hardened --toggle-backend
```

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
- **"401 / 403 from backend"** — if you were logged in via OAuth before, `CLAUDE_CODE_OAUTH_TOKEN` may still be set and the CLI will try to use it against your custom backend. Run `unset CLAUDE_CODE_OAUTH_TOKEN` before launching, or include it in your shell rc file's custom-backend section. `--doctor` will warn when this conflict is detected.
- **"UI shows Sonnet but my backend model is being used"** — that's expected. The `--model` flag aliases all three tiers (Opus/Sonnet/Haiku) to your model, so the UI picker is effectively cosmetic. Check the backend's access log to confirm traffic is going where you want.

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

- **`CLAUDE_VERSION`** — pins the exact official Claude Desktop Linux release (version + SHA256 of the official `.deb`)
- **`TOOL_VERSIONS`** — pins the Claude CLI, cdxgen, vet, and container image digests

All GitHub Actions are pinned to full commit SHAs. Container images are pinned to SHA256 digests. npm packages are installed with `--ignore-scripts`.

### CI pipeline

Every push and PR runs:

- **Shell lint** — `bash -n` on the build pipeline and generated launcher; doctor integration test
- **Package smoke tests** — verifies each built package contains the official payload (`app.asar`, bundled Electron, chrome-sandbox), the launcher, correct permissions, valid desktop entry, and reasonable size
- **Source integrity** — trojan source / Unicode attack scanning on all shell files
- **Dependency scanning** — OWASP depscan for vulnerabilities, vet for malware
- **SBOM** — CycloneDX bill of materials attached to every release

### Automated updates

A CI workflow polls Anthropic's official Linux apt index. When a new version is found, it:

1. Reads the new version and its `.deb` SHA256 straight from the signed `Packages` index
2. Test-builds an RPM in a Fedora container to verify the repackage + build succeed
3. Confirms the official payload (`app.asar`) is present in the built package
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

Anthropic ships an official Claude Desktop Linux `.deb` (a native Linux Electron app that bundles its own Electron runtime and native module). The build script:

1. **Downloads** the official `.deb` from Anthropic's apt repo and verifies it against the SHA256 pinned in `CLAUDE_VERSION` (`lib/download.sh`)
2. **Extracts** the `.deb` payload (`dpkg-deb -x`) — the app under `usr/lib/claude-desktop/`
3. **Stages the payload verbatim** — no `app.asar` patching, no code injection, no native stubs; the official Linux build already works on Linux
4. **Reuses the official icons**, renamed to our app id
5. **Bundles the Claude Code CLI** from npm (pinned, `--ignore-scripts`) for the `claude` command
6. **Generates the hardened launcher** — a bubblewrap wrapper around the official binary (see below)
7. **Packages** as RPM, DEB, or Arch, with post-install hooks for icon caches, desktop database, and chrome-sandbox setuid (used only on the non-sandboxed fallback path)

### The sandbox layer

The launcher (`/usr/bin/claude-desktop-hardened`) runs Anthropic's binary inside a [bubblewrap](https://github.com/containers/bubblewrap) namespace:

- **read-only system** (`/usr`, `/etc`, `/sys`)
- **`$HOME` is default-allow, secrets masked** — the app (and the MCP servers / Cowork / Code sessions it spawns) can work with your files and tools, but `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.config/gcloud`, `~/.kube`, `~/.docker`, `~/.pki`, `~/.local/share/keyrings`, and browser profiles are overlaid with empty tmpfs — invisible to the app
- **devices limited** to GPU (`/dev/dri`), KVM (`/dev/kvm`), and sound (`/dev/snd`)
- **DNS** works inside the sandbox (the resolv.conf target dir is bound)
- Electron's own sandbox is disabled inside bwrap (`--no-sandbox`) because bwrap already provides the namespace isolation

Escape hatch: set `CLAUDE_NO_SANDBOX=1` to launch directly; if `bwrap` isn't installed the launcher falls back to a direct launch with a warning.

### Why the base changed (July 2026)

This project used to download the **Windows `.nupkg`** and force it to run on Linux, which required patching dozens of locations in the minified `app.asar` and stubbing out Windows/macOS native modules. That was fragile — every upstream release could break a patch (missing registry APIs, Windows-only tray icons, etc.). Once Anthropic shipped an **official Linux build**, that entire class of breakage disappeared: we now repackage the real Linux app unmodified and focus purely on the sandbox + supply-chain hardening.

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
