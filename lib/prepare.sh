#!/bin/bash
# Distro-agnostic app preparation: icons, asar patching, stub installation,
# CLI bundling, desktop entry, and launcher script generation.
#
# Requires: WORK_DIR, PKG_ROOT, INSTALL_DIR, INSTALL_LIB_DIR, SCRIPT_DIR, VERSION
# Requires: wrestool, icotool, convert, npx, asar, node, npm, python3

prepare_app() {
    # -----------------------------------------------------------------------
    # Icons
    # -----------------------------------------------------------------------
    log_step "🎨" "Processing icons..."
    cd "$WORK_DIR"

    if ! wrestool -x -t 14 "lib/net45/claude.exe" -o claude.ico; then
        log_error "Failed to extract icons from exe"
        exit 1
    fi
    if ! icotool -x claude.ico; then
        log_error "Failed to convert icons"
        exit 1
    fi
    log_ok "Icons processed"

    declare -A icon_files=(
        ["16"]="claude_13_16x16x32.png"
        ["24"]="claude_11_24x24x32.png"
        ["32"]="claude_10_32x32x32.png"
        ["48"]="claude_8_48x48x32.png"
        ["64"]="claude_7_64x64x32.png"
        ["256"]="claude_6_256x256x32.png"
    )

    for size in 16 24 32 48 64 256; do
        icon_dir="$INSTALL_DIR/share/icons/hicolor/${size}x${size}/apps"
        mkdir -p "$icon_dir"
        if [ -f "${icon_files[$size]}" ]; then
            log_info "Installing ${size}x${size} icon..."
            install -Dm 644 "${icon_files[$size]}" "$icon_dir/claude-desktop-hardened.png"
        else
            log_warn "Missing ${size}x${size} icon"
        fi
    done

    # -----------------------------------------------------------------------
    # App.asar extraction and patching
    # -----------------------------------------------------------------------
    mkdir -p electron-app
    cp "lib/net45/resources/app.asar" electron-app/
    cp -r "lib/net45/resources/app.asar.unpacked" electron-app/

    cd electron-app
    npx asar extract app.asar app.asar.contents || { log_error "asar extract failed"; exit 1; }

    # Replace native module with Linux stub
    log_step "🔧" "Installing claude-native stub..."
    if [ -d "app.asar.contents/node_modules/@ant/claude-native" ]; then
        NATIVE_MOD_DIR="app.asar.contents/node_modules/@ant/claude-native"
        SWIFT_MOD_DIR="app.asar.contents/node_modules/@ant/claude-swift"
    else
        NATIVE_MOD_DIR="app.asar.contents/node_modules/claude-native"
        SWIFT_MOD_DIR="app.asar.contents/node_modules/claude-swift-stub"
    fi
    mkdir -p "$NATIVE_MOD_DIR"
    cp "$SCRIPT_DIR/stubs/claude-native/index.js" "$NATIVE_MOD_DIR/index.js"

    # Install Cowork stubs
    log_step "🔧" "Installing Cowork stubs..."
    mkdir -p "$SWIFT_MOD_DIR"
    cp "$SCRIPT_DIR/stubs/claude-swift-stub/index.js" "$SWIFT_MOD_DIR/index.js"
    if [ -d "app.asar.contents/node_modules/@ant/claude-native" ]; then
        cat > "$SWIFT_MOD_DIR/package.json" << 'SWIFTPKG'
{"name":"@ant/claude-swift","version":"0.0.1","main":"index.js","private":true}
SWIFTPKG
    else
        cp "$SCRIPT_DIR/stubs/claude-swift-stub/package.json" "$SWIFT_MOD_DIR/package.json"
    fi

    mkdir -p app.asar.contents/node_modules/cowork
    for f in "$SCRIPT_DIR"/stubs/cowork/*.js; do
        cp "$f" "app.asar.contents/node_modules/cowork/$(basename "$f")"
    done
    cp "$SCRIPT_DIR/stubs/cowork/package.json" "app.asar.contents/node_modules/cowork/package.json"

    # Cowork platform gate patching
    log_step "🔧" "Patching for Cowork enablement..."
    python3 "$SCRIPT_DIR/enable-cowork.py" app.asar.contents

    # Tray icons — invert RGB to white for dark Linux system trays
    mkdir -p app.asar.contents/resources
    cp ../lib/net45/resources/Tray* app.asar.contents/resources/ 2>/dev/null || true
    for tray_src in app.asar.contents/resources/Tray*.png; do
        [ -f "$tray_src" ] || continue
        convert "$tray_src" -channel RGB -negate "$tray_src" 2>/dev/null && \
            log_info "Tray icon → white: $(basename "$tray_src")" || true
    done

    # Copy 256px icon for window/dock injection at runtime
    if [ -f "$WORK_DIR/claude_6_256x256x32.png" ]; then
        cp "$WORK_DIR/claude_6_256x256x32.png" app.asar.contents/resources/icon.png
    fi

    # i18n resources
    mkdir -p app.asar.contents/resources/i18n/
    cp ../lib/net45/resources/*.json app.asar.contents/resources/i18n/

    # Patch window decorations for Linux CSD
    log_step "🔧" "Patching window decorations..."
    node "$SCRIPT_DIR/scripts/patch-window.js" app.asar.contents

    # Inject startup code: hide menu bar, set window icon, inject Claude icon
    log_step "🔧" "Injecting startup patches..."
    MAIN_JS="app.asar.contents/.vite/build/index.js"
    if [ -f "$MAIN_JS" ]; then
        cat > /tmp/claude-prepend.js << 'PREPENDJS'
const{app:_capp,Menu:_cMenu,nativeImage:_cNI}=require("electron");
const _cPath=require("path");

// Set app identity BEFORE app.ready — this controls the GlobalShortcuts portal
// registration name on KDE, the Wayland app_id, and window grouping.
_capp.name="Claude";
_capp.setDesktopName("claude-desktop-hardened.desktop");

// Load icon once; resize to 48px for in-app title bar injection.
const _iconPath=_cPath.join(__dirname,"..","..","resources","icon.png");
const _iconFull=_cNI.createFromPath(_iconPath);
const _iconSmall=_iconFull.isEmpty()?_iconFull:_iconFull.resize({width:48,height:48});
const _iconDataUrl=_iconSmall.isEmpty()?null:_iconSmall.toDataURL();

// TRAY FIX: Electron on Linux has a bug where Tray.destroy() doesn't properly
// clean up D-Bus exported methods (StatusNotifierItem). When the app recreates
// the tray (e.g. on theme change via nativeTheme "updated" event), the new tray
// fails to re-export its D-Bus interface, resulting in an unresponsive
// StatusNotifierItem (Show App / Quit do nothing on KDE Wayland).
// Fix: intercept require('electron') via Module._load to return a Proxy that
// makes Tray a singleton — destroy() becomes a no-op, new Tray() returns the
// existing instance with updated icon. Context menu / event handlers are
// re-attached by the app's own code after construction.
if(process.platform==="linux"){
  const _Module=require("module");
  const _origLoad=_Module._load;
  let _singletonTray=null;
  _Module._load=function(request,parent,isMain){
    const result=_origLoad.call(this,request,parent,isMain);
    if(request==="electron"&&result&&typeof result==="object"){
      return new Proxy(result,{get(target,prop){
        if(prop==="Tray"){
          const OrigTray=target.Tray;
          return function TrayProxy(icon){
            if(_singletonTray&&!_singletonTray.isDestroyed()){
              try{_singletonTray.setImage(icon);}catch(_){}
              return _singletonTray;
            }
            _singletonTray=new OrigTray(icon);
            _singletonTray.destroy=()=>{};
            return _singletonTray;
          };
        }
        return target[prop];
      }});
    }
    return result;
  };
}

// Minimal Linux integration: hide menu bar, set icon, register missing eipc stubs.

_capp.on("ready",()=>{
  try{if(!_iconFull.isEmpty()&&_capp.setIcon)_capp.setIcon(_iconFull);}catch(ex){}

  // Register stub handlers for eipc interfaces that have no implementation on Linux.
  // The eipc framework's catch-all may register first, so we delay and replace.
  setTimeout(()=>{
    const{ipcMain:_ipc}=require("electron");
    const _eipcPrefix="$eipc_message$_742e51f2-18f9-4a58-bbe9-e8a5cc4381ee_$_";
    // Computer Use TCC stubs — delegate to permission layer for user confirmation
    let _cuPerm;
    try{_cuPerm=require("cowork/computer_use_permission");}catch(_){_cuPerm=null;}
    const _stubs={
      "claude.web_$_ComputerUseTcc_$_getState":       ()=>_cuPerm?_cuPerm.getState():{screenRecording:false,accessibility:false},
      "claude.web_$_ComputerUseTcc_$_requestAccessibility":async()=>_cuPerm?await _cuPerm.requestPermission("accessibility","eipc"):{granted:false},
      "claude.web_$_ComputerUseTcc_$_requestScreenRecording":async()=>_cuPerm?await _cuPerm.requestPermission("screenRecording","eipc"):{granted:false},
      "claude.web_$_ComputerUseTcc_$_openSystemSettings":()=>{},
      "claude.web_$_ComputerUseTcc_$_getCurrentSessionGrants":()=>_cuPerm?_cuPerm.getCurrentSessionGrants():[],
      "claude.web_$_ComputerUseTcc_$_revokeGrant":    (_e,k)=>{if(_cuPerm)_cuPerm.revokeGrant(k);},
      "claude.web_$_ComputerUseTcc_$_listInstalledApps":()=>[],
    };
    for(const[suffix,handler] of Object.entries(_stubs)){
      const ch=_eipcPrefix+suffix;
      try{_ipc.removeHandler(ch);}catch(_){}
      try{_ipc.handle(ch,handler);}catch(_){}
    }
    console.log("[cowork-linux] Registered ComputerUseTcc stubs");

    // Wayland global shortcut via XDG GlobalShortcuts portal.
    // Must spawn from inside Electron so the process is in the named systemd
    // scope — xdg-desktop-portal uses the scope to determine the app ID and
    // rejects callers without one ("An app id is required").
    // Path comes from CLAUDE_SHARE_DIR set by the launcher (no __dirname).
    if(process.env.XDG_SESSION_TYPE==="wayland"||process.env.WAYLAND_DISPLAY){
      try{
        const _shareDir=process.env.CLAUDE_SHARE_DIR||"/usr/share/claude-desktop-hardened";
        const{spawn:_spawnHelper}=require("child_process");
        const{BrowserWindow:_BWHelper}=require("electron");
        const _helper=_spawnHelper("python3",[_shareDir+"/portal-shortcut.py"],{stdio:["pipe","pipe","pipe"]});
        _helper.stdout.on("data",d=>{
          const msg=d.toString().trim();
          if(msg==="READY")console.log("[cowork-linux] Global shortcut registered via portal");
          if(msg==="ACTIVATED"){
            const _wins=_BWHelper.getAllWindows();
            if(_wins.length>0){
              const _w=_wins[0];
              if(_w.isVisible()&&_w.isFocused()){_w.hide();}
              else{_w.show();_w.focus();}
            }
          }
          if(msg.startsWith("PORTAL_ERROR")||msg==="UNAVAILABLE"||msg==="PORTAL_TIMEOUT")
            console.log("[cowork-linux] Portal shortcut unavailable:",msg,"— use claude-desktop-hardened --focus");
        });
        _helper.stderr.on("data",d=>console.error("[cowork-linux] portal-shortcut:",d.toString().trim()));
        _helper.on("error",()=>{});
        _capp.on("before-quit",()=>{try{_helper.kill();}catch(_){}});
      }catch(ex){console.log("[cowork-linux] Portal shortcut setup failed:",ex.message);}
    }
  },2000);
});

// Wayland window activation fix: BrowserWindow.show()/focus() are no-ops on
// most Wayland compositors due to focus-stealing prevention. Override them
// to use compositor-specific activation that bypasses the restriction.
if(process.platform==="linux"&&(process.env.XDG_SESSION_TYPE==="wayland"||process.env.WAYLAND_DISPLAY)){
  const _origShow=require("electron").BrowserWindow.prototype.show;
  const _origFocus=require("electron").BrowserWindow.prototype.focus;
  const{execFileSync:_execSync}=require("child_process");
  const _fs=require("fs");
  const _desktop=process.env.XDG_CURRENT_DESKTOP||"";
  const _activateWayland=function(caller){
    const _tag="[win:"+caller+"]";
    try{
      if(_desktop==="KDE"){
        const _tmp="/tmp/kwin-claude-activate-"+process.pid+".js";
        _fs.writeFileSync(_tmp,'const c=workspace.stackingOrder;for(let i=0;i<c.length;i++){if(c[i].resourceClass&&c[i].resourceClass.toString().toLowerCase().includes("claude")){workspace.activeWindow=c[i];break;}}');
        _execSync("gdbus",["call","--session","--dest","org.kde.KWin","--object-path","/Scripting","--method","org.kde.kwin.Scripting.loadScript",_tmp],{timeout:2000});
        _execSync("gdbus",["call","--session","--dest","org.kde.KWin","--object-path","/Scripting","--method","org.kde.kwin.Scripting.start"],{timeout:2000});
        try{_fs.unlinkSync(_tmp);}catch(_){}
        console.log("[cowork-linux]",_tag,"KWin activate ok");
      }else if(_desktop.includes("Hyprland")||_fs.existsSync("/usr/bin/hyprctl")){
        const _clients=JSON.parse(_execSync("/usr/bin/hyprctl",["clients","-j"],{encoding:"utf8",timeout:2000}));
        const _w=_clients.find(c=>(c.class||"").toLowerCase().includes("claude"));
        if(_w){_execSync("/usr/bin/hyprctl",["dispatch","focuswindow","address:"+_w.address],{timeout:2000});console.log("[cowork-linux]",_tag,"Hyprland activate ok");}
        else console.log("[cowork-linux]",_tag,"Hyprland: no claude window found in clients");
      }else if(_fs.existsSync("/usr/bin/swaymsg")){
        _execSync("/usr/bin/swaymsg",["[app_id=claude-desktop-hardened]","focus"],{timeout:2000});
        console.log("[cowork-linux]",_tag,"Sway activate ok");
      }else if(_desktop==="GNOME"&&_fs.existsSync("/usr/bin/gdbus")){
        _execSync("/usr/bin/gdbus",["call","--session","--dest","org.gnome.Shell","--object-path","/org/gnome/Shell","--method","org.gnome.Shell.Eval",
          'global.get_window_actors().find(a=>{let m=a.meta_window;return m&&(m.get_wm_class()||\"\").toLowerCase().includes(\"claude\")})?.meta_window.activate(global.get_current_time())'],{timeout:2000});
        console.log("[cowork-linux]",_tag,"GNOME activate ok");
      }else{
        console.log("[cowork-linux]",_tag,"no compositor activation method matched, desktop="+_desktop);
      }
    }catch(err){console.log("[cowork-linux]",_tag,"activate failed:",err.message);}
  };
  require("electron").BrowserWindow.prototype.show=function(){
    const _sid=this.id;
    console.log("[cowork-linux] [win:show] id="+_sid+" title="+JSON.stringify(this.getTitle())+" visible="+this.isVisible()+" focused="+this.isFocused());
    _origShow.call(this);
    // Delay activation: give the compositor time to map the surface before
    // requesting focus. Without this, the activation request races the
    // surface-map and KWin may not find the window yet.
    setTimeout(()=>{ _activateWayland("show:"+_sid); },80);
  };
  require("electron").BrowserWindow.prototype.focus=function(){
    console.log("[cowork-linux] [win:focus] id="+this.id+" title="+JSON.stringify(this.getTitle())+" visible="+this.isVisible());
    _origFocus.call(this);
    _activateWayland("focus:"+this.id);
  };
}

_capp.on("browser-window-created",(e,w)=>{
  if(process.platform==="linux"){
    // Hide the visual menu bar but don't touch the Menu object
    w.setAutoHideMenuBar(true);
    w.setMenuBarVisibility(false);
  }
  try{if(!_iconFull.isEmpty())w.setIcon(_iconFull);}catch(ex){}

  // Lifecycle logging — traces tray→show→blur→hide cycles for debugging
  const _wid=w.id;
  const _wtag=()=>"[win#"+_wid+":"+JSON.stringify(w.isDestroyed()?"<destroyed>":w.getTitle())+"]";
  w.on("show",  ()=>console.log("[cowork-linux]",_wtag(),"show  visible="+w.isVisible()+" focused="+w.isFocused()));
  w.on("hide",  ()=>console.log("[cowork-linux]",_wtag(),"hide"));
  w.on("focus", ()=>console.log("[cowork-linux]",_wtag(),"focus"));
  w.on("blur",  ()=>console.log("[cowork-linux]",_wtag(),"blur  visible="+w.isVisible()));
  w.on("close", ()=>console.log("[cowork-linux]",_wtag(),"close"));
  w.on("closed",()=>console.log("[cowork-linux] [win#"+_wid+"] closed"));

  // Wayland focus-stealing prevention causes frameless/transparent windows (like
  // the quick-capture window) to receive a spurious blur immediately after show(),
  // which triggers the app's blur→hide handler before the compositor can grant focus.
  // Suppress blur emissions for 300ms after each show() call, which is enough time
  // for the KWin activation script to complete and the focus event to arrive.
  if(process.env.XDG_SESSION_TYPE==="wayland"||process.env.WAYLAND_DISPLAY){
    let _suppressBlurUntil=0;
    w.on("show",()=>{ _suppressBlurUntil=Date.now()+300; });
    const _origEmit=w.emit.bind(w);
    w.emit=function(event,...args){
      if(event==="blur"&&Date.now()<_suppressBlurUntil){
        console.log("[cowork-linux]",_wtag(),"blur suppressed (within 300ms of show)");
        return false;
      }
      return _origEmit(event,...args);
    };
  }

  if(process.platform!=="linux"||!_iconDataUrl)return;

  // CSS: fixed draggable icon wrapper top-left, 42x44px matching titleBarOverlay height.
  const _css=[
    "#_cld_icon{",
      "position:fixed;top:0;left:0;",
      "width:42px;height:44px;",
      "z-index:2147483647;",
      "display:flex;align-items:center;justify-content:center;",
      "-webkit-app-region:drag;",
      "user-select:none;box-sizing:border-box;padding:9px;",
    "}",
    "#_cld_icon img{",
      "width:100%;height:100%;",
      "pointer-events:none;-webkit-app-region:no-drag;",
      "object-fit:contain;",
      "filter:drop-shadow(0 1px 3px rgba(0,0,0,0.45));",
    "}",
  ].join("");

  // JS: wait for first top-left nav button, shift its container right, append icon.
  const _js=[
    "(function(){",
      "if(document.getElementById('_cld_icon'))return;",
      "const el=document.createElement('div');",
      "el.id='_cld_icon';",
      "const img=document.createElement('img');",
      "img.src='",_iconDataUrl,"';",
      "img.alt='Claude';",
      "el.appendChild(img);",
      "const place=()=>{",
        "const all=Array.from(document.querySelectorAll('button,[role=button],[role=tab]'));",
        "const tl=all.find(b=>{const r=b.getBoundingClientRect();",
          "return r.top>=0&&r.top<52&&r.left>=0&&r.left<100&&r.width>0&&r.height>0;});",
        "if(!tl)return false;",
        "const p=tl.parentElement;",
        "if(p&&!p.dataset.cldShifted){",
          "p.dataset.cldShifted='1';",
          "const pl=parseInt(getComputedStyle(p).paddingLeft)||0;",
          "p.style.paddingLeft=(pl+44)+'px';",
        "}",
        "document.documentElement.appendChild(el);",
        "return true;",
      "};",
      "if(!place()){",
        "const obs=new MutationObserver(()=>{if(place())obs.disconnect();});",
        "obs.observe(document.documentElement,{childList:true,subtree:true});",
        "setTimeout(()=>obs.disconnect(),20000);",
      "}",
    "})();",
  ].join("");

  const inject=()=>{
    const b=w.getBounds();
    if(b.width<500||b.height<300)return;
    w.webContents.insertCSS(_css).catch(()=>{});
    w.webContents.executeJavaScript(_js).catch(()=>{});
  };

  w.webContents.on("dom-ready",inject);
  w.webContents.on("did-navigate-in-page",inject);
});
PREPENDJS
        cat /tmp/claude-prepend.js "$MAIN_JS" > /tmp/claude-combined.js
        mv /tmp/claude-combined.js "$MAIN_JS"
        rm -f /tmp/claude-prepend.js
        log_info "Menu bar hidden + icon injection installed"
    fi

    # Repackage app.asar
    npx asar pack app.asar.contents app.asar || { log_error "asar pack failed"; exit 1; }

    # -----------------------------------------------------------------------
    # Unpacked directory stubs (mirrors the asar contents stubs)
    # -----------------------------------------------------------------------
    if [ -d "app.asar.unpacked/node_modules/@ant/claude-native" ]; then
        UNPACKED_NATIVE="$INSTALL_DIR/lib/$PACKAGE_NAME/app.asar.unpacked/node_modules/@ant/claude-native"
        UNPACKED_SWIFT="$INSTALL_DIR/lib/$PACKAGE_NAME/app.asar.unpacked/node_modules/@ant/claude-swift"
    else
        UNPACKED_NATIVE="$INSTALL_DIR/lib/$PACKAGE_NAME/app.asar.unpacked/node_modules/claude-native"
        UNPACKED_SWIFT="$INSTALL_DIR/lib/$PACKAGE_NAME/app.asar.unpacked/node_modules/claude-swift-stub"
    fi
    mkdir -p "$UNPACKED_NATIVE"
    cp "$SCRIPT_DIR/stubs/claude-native/index.js" "$UNPACKED_NATIVE/index.js"

    mkdir -p "$UNPACKED_SWIFT"
    cp "$SCRIPT_DIR/stubs/claude-swift-stub/index.js" "$UNPACKED_SWIFT/index.js"
    if [ -d "app.asar.unpacked/node_modules/@ant/claude-native" ]; then
        cat > "$UNPACKED_SWIFT/package.json" << 'SWIFTPKG'
{"name":"@ant/claude-swift","version":"0.0.1","main":"index.js","private":true}
SWIFTPKG
    else
        cp "$SCRIPT_DIR/stubs/claude-swift-stub/package.json" "$UNPACKED_SWIFT/package.json"
    fi

    mkdir -p "$INSTALL_DIR/lib/$PACKAGE_NAME/app.asar.unpacked/node_modules/cowork"
    for f in "$SCRIPT_DIR"/stubs/cowork/*.js; do
        cp "$f" "$INSTALL_DIR/lib/$PACKAGE_NAME/app.asar.unpacked/node_modules/cowork/$(basename "$f")"
    done
    cp "$SCRIPT_DIR/stubs/cowork/package.json" "$INSTALL_DIR/lib/$PACKAGE_NAME/app.asar.unpacked/node_modules/cowork/package.json"

    # -----------------------------------------------------------------------
    # Claude Code CLI bundling
    # -----------------------------------------------------------------------
    log_step "📥" "Downloading Claude Code CLI..."
    CLAUDE_CLI_DIR="$INSTALL_DIR/lib/$PACKAGE_NAME/claude-code"
    mkdir -p "$CLAUDE_CLI_DIR"

    # Use pinned version from TOOL_VERSIONS, fall back to npm registry
    if [ -z "${CLAUDE_CLI_VERSION:-}" ]; then
        CLAUDE_CLI_VERSION=$(curl -s https://registry.npmjs.org/@anthropic-ai/claude-code/latest | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','latest'))" 2>/dev/null || echo "latest")
        log_warn "Claude CLI version not pinned in TOOL_VERSIONS — using $CLAUDE_CLI_VERSION from registry"
    fi
    echo "📋 Claude Code CLI version: $CLAUDE_CLI_VERSION"

    cd "$CLAUDE_CLI_DIR"
    npm init -y > /dev/null 2>&1
    npm install "@anthropic-ai/claude-code@${CLAUDE_CLI_VERSION}" --save --ignore-scripts > /dev/null 2>&1

    # CLI wrapper script
    mkdir -p "$INSTALL_DIR/bin"
    cat > "$INSTALL_DIR/bin/claude" << CLIEOF
#!/bin/bash
# Claude Code CLI - bundled with Claude Desktop for Linux
NODE_PATH="${INSTALL_LIB_DIR}/claude-code/node_modules" \\
  exec node ${INSTALL_LIB_DIR}/claude-code/node_modules/@anthropic-ai/claude-code/cli.js "\$@"
CLIEOF
    chmod +x "$INSTALL_DIR/bin/claude"

    cd "$WORK_DIR/electron-app"
    log_ok "Claude Code CLI bundled"

    # -----------------------------------------------------------------------
    # App files, desktop entry, launcher
    # -----------------------------------------------------------------------
    cp app.asar "$INSTALL_DIR/lib/$PACKAGE_NAME/"
    cp -r app.asar.unpacked "$INSTALL_DIR/lib/$PACKAGE_NAME/"

    # Helper scripts
    mkdir -p "$INSTALL_DIR/share/$PACKAGE_NAME"
    install -m 755 "$SCRIPT_DIR/scripts/doctor.sh" "$INSTALL_DIR/share/$PACKAGE_NAME/doctor.sh"
    install -m 755 "$SCRIPT_DIR/scripts/focus.sh" "$INSTALL_DIR/share/$PACKAGE_NAME/focus.sh"
    install -m 755 "$SCRIPT_DIR/scripts/portal-shortcut.py" "$INSTALL_DIR/share/$PACKAGE_NAME/portal-shortcut.py"

    # Desktop entry
    cat > "$INSTALL_DIR/share/applications/claude-desktop-hardened.desktop" << EOF
[Desktop Entry]
Name=Claude (Hardened)
Exec=claude-desktop-hardened %u
Icon=claude-desktop-hardened
Type=Application
Terminal=false
Categories=Office;Utility;
MimeType=x-scheme-handler/claude;
StartupWMClass=claude-desktop-hardened
Actions=quit;

[Desktop Action quit]
Name=Quit Claude
Exec=sh -c 'pkill -f "electron.*claude-desktop-hardened/app.asar" || pkill -f claude-desktop-hardened'
EOF

    # Launcher script with Wayland detection, keyring support, logging
    cat > "$INSTALL_DIR/bin/claude-desktop-hardened" << LAUNCHEREOF
#!/bin/bash

# Tell Chromium/Electron which .desktop file we belong to.
# This sets the Wayland app_id so the compositor can match windows to the
# desktop entry (icon, pinning, etc.).
export CHROME_DESKTOP="claude-desktop-hardened.desktop"

# Detect display server for Electron and Computer Use tools
if [ -n "\$WAYLAND_DISPLAY" ] || [ "\$XDG_SESSION_TYPE" = "wayland" ]; then
    export CLAUDE_DISPLAY_SERVER="wayland"
    export ELECTRON_OZONE_PLATFORM_HINT="\${ELECTRON_OZONE_PLATFORM_HINT:-wayland}"
elif [ -n "\$DISPLAY" ]; then
    export CLAUDE_DISPLAY_SERVER="x11"
else
    export CLAUDE_DISPLAY_SERVER="headless"
fi

# Detect keyring provider via D-Bus for credential storage
KEYRING_FLAG=""
if command -v dbus-send >/dev/null 2>&1; then
    if ! dbus-send --session --print-reply --dest=org.freedesktop.DBus \\
        /org/freedesktop/DBus org.freedesktop.DBus.ListNames 2>/dev/null | \\
        grep -q "org.freedesktop.secrets"; then
        KEYRING_FLAG="--password-store=basic"
    fi
else
    KEYRING_FLAG="--password-store=basic"
fi

# Handle special flags
case "\${1:-}" in
    --doctor) exec "${INSTALL_LIB_DIR}/../../share/claude-desktop-hardened/doctor.sh" ;;
    --focus)  exec "${INSTALL_LIB_DIR}/../../share/claude-desktop-hardened/focus.sh" ;;
esac

LOG_FILE="\$HOME/claude-desktop-hardened-launcher.log"

# Export the share dir so the injected JS can find helpers at runtime.
# The helper must be spawned from inside Electron (which runs in a named
# systemd scope) so that xdg-desktop-portal can identify the app ID.
# Spawning from the shell launcher (before exec systemd-run) puts the helper
# outside the scope and triggers "An app id is required" from the portal.
export CLAUDE_SHARE_DIR="${INSTALL_LIB_DIR}/../../share/claude-desktop-hardened"

# Launch Electron inside a correctly-named systemd scope so that
# xdg-desktop-portal identifies the app as "claude-desktop-hardened"
# (instead of "org.chromium.Chromium"). This fixes the GlobalShortcuts
# portal registration name in KDE System Settings and other portal interactions.
ELECTRON_ARGS="\\
    --class=claude-desktop-hardened \\
    --name=claude-desktop-hardened \\
    --ozone-platform-hint=auto \\
    --enable-features=GlobalShortcutsPortal \\
    --enable-logging=file \\
    --log-file=\$LOG_FILE \\
    --log-level=INFO \\
    \$KEYRING_FLAG"

if command -v systemd-run >/dev/null 2>&1; then
    exec systemd-run --user --scope \\
        --unit="app-claude\\\\x2ddesktop\\\\x2dhardened-\$\$.scope" \\
        -- electron ${INSTALL_LIB_DIR}/app.asar \$ELECTRON_ARGS "\$@"
else
    exec electron ${INSTALL_LIB_DIR}/app.asar \$ELECTRON_ARGS "\$@"
fi
LAUNCHEREOF
    chmod +x "$INSTALL_DIR/bin/claude-desktop-hardened"
}
