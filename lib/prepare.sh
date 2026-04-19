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

    # cowork-plugin-shim.sh is installed as a real filesystem file alongside
    # app.asar in the install phase below (not inside the asar).

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

// PRELOAD FIX: Electron 35+ sandboxed renderers cannot read from the asar VFS.
// Preload scripts inside the asar fail during execution because the eipc origin
// validator rejects calls from file:// origins. The preloads are extracted to
// real filesystem at .vite/build/ alongside the asar. We intercept BrowserWindow
// creation via Module._load to redirect preload paths to the real copies.
// NOTE: require("electron").BrowserWindow is read-only, so we MUST intercept
// via the Module._load Proxy, not by direct assignment.

// Load icon once; resize to 48px for in-app title bar injection.
const _iconPath=_cPath.join(__dirname,"..","..","resources","icon.png");
const _iconFull=_cNI.createFromPath(_iconPath);
const _iconSmall=_iconFull.isEmpty()?_iconFull:_iconFull.resize({width:48,height:48});
const _iconDataUrl=_iconSmall.isEmpty()?null:_iconSmall.toDataURL();

// MODULE._LOAD PROXY: intercept require('electron') to fix Tray singleton
// and redirect BrowserWindow preload paths from asar VFS to real filesystem.
if(process.platform==="linux"){
  const _Module=require("module");
  const _origLoad=_Module._load;
  let _singletonTray=null;
  // Preload redirect: asar path → real filesystem copy
  const _asarPath=_capp.getAppPath();
  const _appDir=_cPath.dirname(_asarPath);
  const _fs=require("fs");
  // Helper: redirect preload inside opts if it points inside the asar
  const _redirectPreload=function(opts){
    if(opts&&opts.webPreferences&&opts.webPreferences.preload){
      const p=opts.webPreferences.preload;
      if(p.startsWith(_asarPath+"/")){
        const rel=p.slice(_asarPath.length);
        const real=_cPath.join(_appDir,rel);
        try{_fs.accessSync(real);opts.webPreferences.preload=real;
          console.log("[cowork-linux] preload redirected:",_cPath.basename(real));
        }catch(e){console.warn("[cowork-linux] preload redirect failed: "+real+" not readable:",e.message);}
      }
    }
  };
  const _electron=require("electron");
  const _OrigBW=_electron.BrowserWindow;
  const _BWProxy=new Proxy(_OrigBW,{
    construct(target,args){
      _redirectPreload(args[0]||{});
      return Reflect.construct(target,args,target);
    }
  });
  const _OrigWCV=_electron.WebContentsView;
  const _WCVProxy=_OrigWCV?new Proxy(_OrigWCV,{
    construct(target,args){
      _redirectPreload(args[0]||{});
      return Reflect.construct(target,args,target);
    }
  }):null;
  _Module._load=function(request,parent,isMain){
    const result=_origLoad.call(this,request,parent,isMain);
    if(request==="electron"&&result&&typeof result==="object"){
      return new Proxy(result,{get(target,prop){
        if(prop==="BrowserWindow") return _BWProxy;
        if(prop==="WebContentsView"&&_WCVProxy) return _WCVProxy;
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

  // Create VM bundle marker files so the download-status check returns "Ready".
  // On Linux we run Claude Code natively (no VM), but the app checks for the
  // manifest file ("native") and its origin stamp (.native.origin containing the
  // manifest sha). Without these, the UI shows a "Download" banner.
  try{
    const _vmBundleDir=require("path").join(_capp.getPath("userData"),"vm_bundles","claudevm.bundle");
    require("fs").mkdirSync(_vmBundleDir,{recursive:true});
    const _nativePath=require("path").join(_vmBundleDir,"native");
    const _originPath=require("path").join(_vmBundleDir,".native.origin");
    if(!require("fs").existsSync(_nativePath))require("fs").writeFileSync(_nativePath,"linux-native");
    // .native.origin must contain the VM manifest SHA for the download check to pass.
    // The SHA is extracted at build time by patch_vm_manifest.py and saved to .vm-sha.
    const _asarPath=require("path").join(__dirname,"..","..",".vm-sha");
    let _vmSha="";
    try{_vmSha=require("fs").readFileSync(_asarPath,"utf8").trim();}catch(_){}
    if(_vmSha){
      require("fs").writeFileSync(_originPath,_vmSha);
      console.log("[cowork-linux] VM markers created (sha: "+_vmSha.slice(0,12)+"...)");
    }else{
      console.warn("[cowork-linux] .vm-sha not found in asar — VM download banner may appear");
    }
  }catch(ex){console.error("[cowork-linux] VM marker creation failed:",ex.message);}

  // Enable computer use (chicagoEnabled) on Linux. The app reads user preferences
  // from claude_desktop_config.json under the "preferences" key, NOT config.json.
  // This ensures the setting is on so computer use tools are offered to the model.
  try{
    const _cdcPath=require("path").join(_capp.getPath("userData"),"claude_desktop_config.json");
    let _cdc={};
    try{_cdc=JSON.parse(require("fs").readFileSync(_cdcPath,"utf8"));}catch(_){}
    if(!_cdc.preferences)_cdc.preferences={};
    if(!_cdc.preferences.chicagoEnabled){
      _cdc.preferences.chicagoEnabled=true;
      require("fs").writeFileSync(_cdcPath,JSON.stringify(_cdc,null,2));
      console.log("[cowork-linux] Enabled chicagoEnabled (computer use) in preferences");
    }
  }catch(ex){console.error("[cowork-linux] Failed to enable computer use config:",ex.message);}

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

// ===== Permanent title bar layout =====
// The titleBarOverlay draws native window controls (min/max/close) in a
// 40px-tall band across the top-right of the window. The scripts/patch-
// window.js asar patch shifts the main Claude WebContentsView down by
// 40px natively, so Claude's layout uses `100vh = windowHeight - 40`
// inside its own view and nothing is clipped, overflows, or needs CSS
// hacks to fit.
//
// No-drag CSS is ONLY needed on the Claude WebContentsView, not the main
// BrowserWindow. The main window's webContents IS the title bar shell —
// its body MUST remain drag-enabled so the overlay compositor treats the
// entire title bar zone as a native drag region (right-click → DE system
// menu, left-click → window drag, double-click → maximize/restore).
//
// The Claude view (at y=40) is entirely below the overlay zone, so there
// is no overlap. But claude.ai may set -webkit-app-region:drag on some
// of its own elements (designed for the macOS traffic-light inset), which
// would create unwanted drag regions inside the Claude UI — the no-drag
// override prevents that.
const _titlebarH=40;
const _noDragCss="body,body *{-webkit-app-region:no-drag !important;}";

if(process.platform==="linux"){
  _capp.on("web-contents-created",(e,wc)=>{
    // Skip BrowserWindow webContents — their title bar must stay draggable.
    if(require("electron").BrowserWindow.fromWebContents(wc))return;
    const _apply=()=>{wc.insertCSS(_noDragCss).catch(()=>{});};
    wc.on("dom-ready",_apply);
    wc.on("did-navigate-in-page",_apply);
  });
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

  // CSS: fixed icon wrapper at top-left of the title bar, 40x40 to match
  // the titleBarOverlay height. The Claude UI is pushed down 40px (see the
  // injected reservation CSS in web-contents-created above), so the icon
  // and nav buttons no longer fight for vertical space — no horizontal
  // shift of the nav container needed.
  const _css=[
    "#_cld_icon{",
      "position:fixed;top:0;left:0;",
      "width:40px;height:40px;",
      "z-index:2147483647;",
      "display:flex;align-items:center;justify-content:center;",
      // Part of the title bar drag region. Left-click = drag (standard),
      // right-click = native DE system menu (KDE/GNOME show Maximize,
      // Minimize, Close, etc.). Electron's titleBarOverlay is a compositor
      // layer above web content — left-click can't be intercepted for a
      // custom menu, but right-click triggers the DE's own window menu.
      "-webkit-app-region:drag !important;",
      "user-select:none;box-sizing:border-box;padding:8px;",
    "}",
    "#_cld_icon img{",
      "width:100%;height:100%;",
      "pointer-events:none;-webkit-app-region:no-drag !important;",
      "object-fit:contain;",
      "filter:drop-shadow(0 1px 3px rgba(0,0,0,0.45));",
    "}",
    // Drag region across the rest of the title bar (left of the window
    // controls). The titleBarOverlay area itself is draggable in pixels
    // not occupied by the buttons, but this gives a guaranteed wide strip.
    // NOTE: starts after the backend chip so clicks on the chip aren't
    // intercepted by the drag region.
    "#_cld_drag_edge{",
      "position:fixed;top:0;left:260px;right:160px;",
      "height:40px;",
      "z-index:2147483646;",
      "-webkit-app-region:drag !important;",
      "user-select:none;",
    "}",
    // Backend segmented control — two pills side-by-side (Anthropic |
    // local-model-name). Active pill is highlighted, inactive is faded.
    // no-drag island inside the title bar drag region so clicks register
    // normally. Hover on either pill shows a native tooltip.
    "#_cdh_backend_chip{",
      "position:fixed;top:4px;left:48px;height:32px;",
      "display:flex;align-items:stretch;",
      "border-radius:16px;overflow:hidden;",
      "background:rgba(255,255,255,0.06);",
      "border:1px solid rgba(255,255,255,0.12);",
      "font:500 12px/1 system-ui,-apple-system,sans-serif;",
      "user-select:none;",
      "-webkit-app-region:no-drag !important;",
      "z-index:2147483647;",
      "max-width:320px;",
    "}",
    "#_cdh_backend_chip .cdh-seg{",
      "display:flex;align-items:center;gap:6px;",
      "padding:0 12px;cursor:pointer;",
      "color:rgba(255,255,255,0.5);",
      "transition:color .12s ease,background .12s ease;",
    "}",
    "#_cdh_backend_chip .cdh-seg:hover{color:rgba(255,255,255,0.9);background:rgba(255,255,255,0.08);}",
    // Active state — Anthropic
    "#_cdh_backend_chip .cdh-seg.cdh-active[data-target=\"anthropic\"]{",
      "color:#e5c07b;background:rgba(229,192,123,0.15);",
    "}",
    // Active state — Local
    "#_cdh_backend_chip .cdh-seg.cdh-active[data-target=\"local\"]{",
      "color:#7ee787;background:rgba(126,231,135,0.18);",
    "}",
    // Disabled state — Local without config
    "#_cdh_backend_chip .cdh-seg.cdh-disabled{",
      "color:rgba(255,255,255,0.25);cursor:help;",
    "}",
    "#_cdh_backend_chip .cdh-seg.cdh-disabled:hover{color:rgba(255,255,255,0.4);background:transparent;}",
    "#_cdh_backend_chip .cdh-dot{",
      "width:6px;height:6px;border-radius:50%;",
      "background:currentColor;flex-shrink:0;",
    "}",
    "#_cdh_backend_chip .cdh-label{",
      "overflow:hidden;text-overflow:ellipsis;white-space:nowrap;",
      "max-width:160px;",
    "}",
    "#_cdh_backend_chip .cdh-divider{",
      "width:1px;background:rgba(255,255,255,0.12);",
    "}",
  ].join("");

  // Resolve the current backend mode from env + config. Runs in main,
  // then gets injected as a JS literal into the renderer's chip.
  const _resolveBackendMode=()=>{
    const envUrl=process.env.ANTHROPIC_BASE_URL;
    const envModel=process.env.ANTHROPIC_MODEL||process.env.ANTHROPIC_DEFAULT_SONNET_MODEL;
    if(envUrl){
      return{mode:"local",baseUrl:envUrl,model:envModel||"custom",source:"env"};
    }
    try{
      const cfgPath=require("path").join(
        process.env.XDG_CONFIG_HOME||require("path").join(require("os").homedir(),".config"),
        "Claude","custom-backend.json"
      );
      if(require("fs").existsSync(cfgPath)){
        const cfg=JSON.parse(require("fs").readFileSync(cfgPath,"utf8"));
        if(cfg&&cfg.enabled&&cfg.baseUrl){
          return{mode:"local",baseUrl:cfg.baseUrl,model:cfg.model||"custom",source:"config"};
        }
        if(cfg&&cfg.baseUrl){
          // Configured but toggled off — report as anthropic but carry
          // the config so the chip tooltip can say "Click to switch to X"
          return{mode:"anthropic",configured:{baseUrl:cfg.baseUrl,model:cfg.model||"?"}};
        }
      }
    }catch(_){}
    return{mode:"anthropic"};
  };

  // JS: append icon + chip + drag strip to documentElement. The chip is
  // a segmented control with two pills (Anthropic | local-model). Active
  // pill is colored, inactive is faded. Click either to switch modes.
  // Re-inject fully on every call so config-change refreshes update the UI.
  const _bmState=_resolveBackendMode();
  const _bmStateJson=JSON.stringify(_bmState);
  const _js=[
    "(function(){",
      "const _state=",_bmStateJson,";",
      // Icon (create once; re-injections are no-ops via the id check)
      "if(!document.getElementById('_cld_icon')){",
        "const el=document.createElement('div');",
        "el.id='_cld_icon';",
        "const img=document.createElement('img');",
        "img.src='",_iconDataUrl,"';",
        "img.alt='Claude';",
        "el.appendChild(img);",
        "document.documentElement.appendChild(el);",
      "}",
      // Backend segmented control — rebuilt fresh on every inject so
      // re-injections from config changes refresh the visible state.
      "let oldChip=document.getElementById('_cdh_backend_chip');",
      "if(oldChip)oldChip.remove();",
      "const chip=document.createElement('div');",
      "chip.id='_cdh_backend_chip';",

      // Anthropic segment (always clickable)
      "const segA=document.createElement('div');",
      "segA.className='cdh-seg';",
      "segA.dataset.target='anthropic';",
      "const dotA=document.createElement('span');dotA.className='cdh-dot';",
      "const lblA=document.createElement('span');lblA.className='cdh-label';",
      "lblA.textContent='Anthropic';",
      "segA.appendChild(dotA);segA.appendChild(lblA);",

      "const divider=document.createElement('div');",
      "divider.className='cdh-divider';",

      // Local segment (disabled if no config)
      "const segL=document.createElement('div');",
      "segL.className='cdh-seg';",
      "segL.dataset.target='local';",
      "const dotL=document.createElement('span');dotL.className='cdh-dot';",
      "const lblL=document.createElement('span');lblL.className='cdh-label';",
      "const hasLocal=_state.mode==='local'||!!_state.configured;",
      "const localModel=_state.mode==='local'?_state.model:(_state.configured&&_state.configured.model)||'Local';",
      "lblL.textContent=hasLocal?localModel:'Local (not set)';",
      "segL.appendChild(dotL);segL.appendChild(lblL);",

      // Mark active / disabled
      "if(_state.mode==='anthropic'){",
        "segA.classList.add('cdh-active');",
        "if(!hasLocal)segL.classList.add('cdh-disabled');",
      "}else{",
        "segL.classList.add('cdh-active');",
      "}",

      // Tooltips
      "if(_state.mode==='anthropic'){",
        "segA.title='Active: Anthropic (default)';",
        "segL.title=hasLocal?",
          "('Switch to local: '+localModel+' @ '+(_state.configured&&_state.configured.baseUrl||'')+' (applies to next Code session)'):",
          "'No local backend configured yet.\\nSet up with:\\n  claude-desktop-hardened --model NAME --base-url URL';",
      "}else{",
        "segL.title='Active: '+localModel+' @ '+_state.baseUrl+'\\nSource: '+(_state.source==='env'?'shell env var':'config file');",
        "segA.title='Switch to Anthropic (applies to next Code session)';",
      "}",

      // Click handlers — only if action would actually change state
      "segA.addEventListener('click',function(e){",
        "e.stopPropagation();",
        "if(_state.mode==='anthropic')return;",
        "console.log('__CDH_BACKEND_SET__anthropic');",
      "});",
      "segL.addEventListener('click',function(e){",
        "e.stopPropagation();",
        "if(!hasLocal){",
          "console.log('__CDH_BACKEND_INFO__no-local-config');",
          "return;",
        "}",
        "if(_state.mode==='local')return;",
        "console.log('__CDH_BACKEND_SET__local');",
      "});",

      "chip.appendChild(segA);",
      "chip.appendChild(divider);",
      "chip.appendChild(segL);",
      "document.documentElement.appendChild(chip);",

      // Drag edge
      "if(!document.getElementById('_cld_drag_edge')){",
        "const edge=document.createElement('div');",
        "edge.id='_cld_drag_edge';",
        "document.documentElement.appendChild(edge);",
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

  // Permanent 40px title bar at the top of the window. The asar patch
  // shifts Claude's WebContentsView down by 40px so nothing in the app
  // sits behind the window controls.
  try{w.setTitleBarOverlay({color:"#00000000",symbolColor:"#ffffff",height:_titlebarH});}catch(e){}

  // Backend segmented control: renderer fires one of two sentinels
  //   __CDH_BACKEND_SET__anthropic
  //   __CDH_BACKEND_SET__local
  // main flips the config's `enabled` accordingly and re-injects the chip.
  // Already-running Code sessions keep their original env — the flip only
  // affects future spawns via the stub's dynamic filterEnv() lookup.
  const _cdhBackendCfgPath=require("path").join(
    process.env.XDG_CONFIG_HOME||require("path").join(require("os").homedir(),".config"),
    "Claude","custom-backend.json"
  );
  const _cdhSetBackend=(target)=>{
    try{
      let cfg={};
      try{cfg=JSON.parse(require("fs").readFileSync(_cdhBackendCfgPath,"utf8"));}catch(_){}
      const want=target==="local";
      if(cfg.enabled===want)return;// already in that state
      cfg.enabled=want;
      require("fs").mkdirSync(require("path").dirname(_cdhBackendCfgPath),{recursive:true});
      require("fs").writeFileSync(_cdhBackendCfgPath,JSON.stringify(cfg,null,2));
      console.log("[cowork-linux] Backend →",want?"local":"anthropic","(next Code session picks this up)");
      inject();
    }catch(ex){
      console.error("[cowork-linux] Backend set failed:",ex.message);
    }
  };
  w.webContents.on("console-message",(...args)=>{
    const msg=(args[0]&&args[0].message)||(args.length>=3?args[2]:"");
    if(msg==="__CDH_BACKEND_SET__anthropic")_cdhSetBackend("anthropic");
    else if(msg==="__CDH_BACKEND_SET__local")_cdhSetBackend("local");
    else if(msg==="__CDH_BACKEND_INFO__no-local-config"){
      console.log("[cowork-linux] No local backend configured — run: claude-desktop-hardened --model NAME --base-url URL");
    }
  });

  // Real-time refresh: watch the config file so external edits
  // (--use-local from another shell, direct JSON edit, etc.) update
  // the chip in the running app without needing a restart.
  try{
    const _fs=require("fs");
    _fs.mkdirSync(require("path").dirname(_cdhBackendCfgPath),{recursive:true});
    // Touch the file so fs.watch has something to watch even before config exists.
    if(!_fs.existsSync(_cdhBackendCfgPath)){
      _fs.writeFileSync(_cdhBackendCfgPath,JSON.stringify({enabled:false},null,2));
    }
    let _cdhRefreshTimer=null;
    const _cdhWatcher=_fs.watch(_cdhBackendCfgPath,{persistent:false},()=>{
      // Debounce — file writers often fire multiple events in quick succession.
      clearTimeout(_cdhRefreshTimer);
      _cdhRefreshTimer=setTimeout(()=>{
        if(!w.isDestroyed())inject();
      },100);
    });
    w.on("closed",()=>{try{_cdhWatcher.close();}catch(_){}});
  }catch(ex){
    console.log("[cowork-linux] Backend config watcher setup failed (non-fatal):",ex.message);
  }
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

    # cowork-plugin-shim.sh — the cowork permission bridge expects this as a real
    # file alongside app.asar (not inside the packed asar). On macOS this is a
    # native TCC shim; on Linux it's a no-op stub.
    cat > "$INSTALL_DIR/lib/$PACKAGE_NAME/cowork-plugin-shim.sh" << 'SHIMEOF'
#!/bin/sh
# cowork-plugin-shim stub for Linux — no-op.
# Plugin permissions on Linux are handled directly via Electron IPC.
exit 0
SHIMEOF
    chmod 755 "$INSTALL_DIR/lib/$PACKAGE_NAME/cowork-plugin-shim.sh"
    log_ok "cowork-plugin-shim.sh stub installed"

    # Extract preload scripts to real filesystem so sandboxed Electron renderers
    # (Electron 35+ enables sandbox by default) can load them. Preloads inside
    # asars fail silently in sandboxed mode because the renderer subprocess's
    # filesystem view does not include the asar VFS.
    mkdir -p "$INSTALL_DIR/lib/$PACKAGE_NAME/.vite/build"
    for _preload in aboutWindow mainWindow mainView quickWindow findInPage computerUseTeach coworkArtifact; do
        if [ -f "app.asar.contents/.vite/build/${_preload}.js" ]; then
            cp "app.asar.contents/.vite/build/${_preload}.js" \
               "$INSTALL_DIR/lib/$PACKAGE_NAME/.vite/build/${_preload}.js"
        fi
    done

    # Patch mainWindow.js preload: wrap getInitialLocale() in try-catch so the
    # preload survives the initial file:// page load. The eipc origin validator
    # only accepts https://claude.ai, rejecting file:// and crashing the preload
    # before window.process / window.initialLocale are exposed.
    _mw="$INSTALL_DIR/lib/$PACKAGE_NAME/.vite/build/mainWindow.js"
    if [ -f "$_mw" ]; then
        python3 - "$_mw" << 'PYEOF'
import sys, re
path = sys.argv[1]
content = open(path).read()
# Match: const{messages:VAR1,locale:VAR2}=IFACE.getInitialLocale();
m = re.search(r'const\{messages:(\w+),locale:(\w+)\}=(\w+)\.getInitialLocale\(\)', content)
if m:
    v1, v2, iface = m.group(1), m.group(2), m.group(3)
    old = m.group(0)
    new = (f'let {v1}=[],{v2}="en-US";'
           f'try{{const _r={iface}.getInitialLocale();{v1}=_r.messages;{v2}=_r.locale;}}catch(_e){{}}')
    content = content.replace(old, new, 1)
    open(path, 'w').write(content)
    print('  [ok] Patched mainWindow.js: getInitialLocale() wrapped in try-catch')
else:
    print('  [warn] mainWindow.js: getInitialLocale() pattern not found — skipping')
PYEOF
    fi

    # Helper scripts
    mkdir -p "$INSTALL_DIR/share/$PACKAGE_NAME"
    install -m 644 "$SCRIPT_DIR/lib/display-server.sh" "$INSTALL_DIR/share/$PACKAGE_NAME/display-server.sh"
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

# Backend config file path — shared with the stub (stubs/claude-swift-stub/
# index.js reads the same file at spawn time) and the title-bar toggle UI.
BACKEND_CFG="\${XDG_CONFIG_HOME:-\$HOME/.config}/Claude/custom-backend.json"

# Helper: write the backend config (uses python3 which is a hard dep on
# Fedora/Debian and available on Arch-with-python). Falls back to a simple
# jq-style hand-rolled writer if python3 is somehow missing.
_cdh_write_backend_cfg() {
    local enabled="\$1" base_url="\$2" model="\$3"
    mkdir -p "\$(dirname "\$BACKEND_CFG")"
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "
import json, os, sys
path = '\$BACKEND_CFG'
existing = {}
if os.path.exists(path):
    try:
        with open(path) as f: existing = json.load(f) or {}
    except: pass
existing['enabled'] = '\$enabled' == 'true'
if '\$base_url': existing['baseUrl'] = '\$base_url'
if '\$model':    existing['model']   = '\$model'
with open(path, 'w') as f: json.dump(existing, f, indent=2)
"
    fi
}

# Handle special flags and custom-backend overrides. --model / --base-url
# are consumed here and converted to env vars (ANTHROPIC_MODEL /
# ANTHROPIC_BASE_URL) which the Claude Code CLI reads at startup. They're
# shifted off \$@ so they don't get forwarded to Electron as unknown args.
#
# Secrets (API keys, auth tokens) are deliberately NOT accepted as flags —
# they'd leak into \`ps aux\` and shell history. Use env vars or a sourced
# secrets file instead. See README → "Using a custom model backend".
while [[ "\${1:-}" == --* ]]; do
    case "\$1" in
        --doctor)
            exec "\${CLAUDE_SHARE_DIR:-${INSTALL_LIB_DIR}/../../share/claude-desktop-hardened}/doctor.sh"
            ;;
        --focus)
            exec "\${CLAUDE_SHARE_DIR:-${INSTALL_LIB_DIR}/../../share/claude-desktop-hardened}/focus.sh"
            ;;
        --toggle-backend)
            # Flip the "enabled" flag in the backend config. For keyboard
            # shortcut bindings. Prints the new state and exits.
            if command -v python3 >/dev/null 2>&1; then
                python3 -c "
import json, os
p = '\$BACKEND_CFG'
cfg = {}
if os.path.exists(p):
    try:
        with open(p) as f: cfg = json.load(f) or {}
    except: pass
cfg['enabled'] = not cfg.get('enabled', False)
os.makedirs(os.path.dirname(p), exist_ok=True)
with open(p, 'w') as f: json.dump(cfg, f, indent=2)
state = 'Local (' + cfg.get('model', '?') + ')' if cfg['enabled'] else 'Anthropic'
print('Backend toggled →', state)
print('Affects the next Code session you start; current sessions keep their env.')
"
            else
                echo "Error: python3 required for --toggle-backend" >&2
                exit 1
            fi
            exit 0
            ;;
        --use-local)
            # Explicitly enable the configured local backend (no toggle).
            _cdh_write_backend_cfg true "" ""
            echo "Backend → Local (uses configured baseUrl/model from \$BACKEND_CFG)"
            exit 0
            ;;
        --use-anthropic)
            # Explicitly revert to Anthropic upstream.
            _cdh_write_backend_cfg false "" ""
            echo "Backend → Anthropic"
            exit 0
            ;;
        --model)
            if [ -z "\${2:-}" ]; then
                echo "Error: --model requires a value (e.g. --model claude-sonnet-4-5-20250929)" >&2
                exit 1
            fi
            # Set ALL the tier mappings so the UI's Sonnet/Opus/Haiku picker
            # maps to this model regardless of which tier the user selects.
            # Without this, the UI spawns the CLI with --model <tier-name>
            # which overrides ANTHROPIC_MODEL. Users can still override per
            # tier by setting ANTHROPIC_DEFAULT_*_MODEL directly.
            export ANTHROPIC_MODEL="\$2"
            export ANTHROPIC_DEFAULT_OPUS_MODEL="\${ANTHROPIC_DEFAULT_OPUS_MODEL:-\$2}"
            export ANTHROPIC_DEFAULT_SONNET_MODEL="\${ANTHROPIC_DEFAULT_SONNET_MODEL:-\$2}"
            export ANTHROPIC_DEFAULT_HAIKU_MODEL="\${ANTHROPIC_DEFAULT_HAIKU_MODEL:-\$2}"
            export ANTHROPIC_SMALL_FAST_MODEL="\${ANTHROPIC_SMALL_FAST_MODEL:-\$2}"
            # Persist to config so the title-bar toggle reflects this model
            # and can be flipped on/off without re-specifying the flag.
            _cdh_write_backend_cfg true "" "\$2"
            shift 2
            ;;
        --model=*)
            _cdh_m="\${1#--model=}"
            export ANTHROPIC_MODEL="\$_cdh_m"
            export ANTHROPIC_DEFAULT_OPUS_MODEL="\${ANTHROPIC_DEFAULT_OPUS_MODEL:-\$_cdh_m}"
            export ANTHROPIC_DEFAULT_SONNET_MODEL="\${ANTHROPIC_DEFAULT_SONNET_MODEL:-\$_cdh_m}"
            export ANTHROPIC_DEFAULT_HAIKU_MODEL="\${ANTHROPIC_DEFAULT_HAIKU_MODEL:-\$_cdh_m}"
            export ANTHROPIC_SMALL_FAST_MODEL="\${ANTHROPIC_SMALL_FAST_MODEL:-\$_cdh_m}"
            _cdh_write_backend_cfg true "" "\$_cdh_m"
            unset _cdh_m
            shift
            ;;
        --base-url)
            if [ -z "\${2:-}" ]; then
                echo "Error: --base-url requires a value (e.g. --base-url http://localhost:4000)" >&2
                exit 1
            fi
            export ANTHROPIC_BASE_URL="\$2"
            _cdh_write_backend_cfg true "\$2" ""
            shift 2
            ;;
        --base-url=*)
            _cdh_u="\${1#--base-url=}"
            export ANTHROPIC_BASE_URL="\$_cdh_u"
            _cdh_write_backend_cfg true "\$_cdh_u" ""
            unset _cdh_u
            shift
            ;;
        --)
            shift
            break
            ;;
        *)
            # Unknown flag — let Electron handle it (some flags like
            # --disable-gpu are valid Chromium flags users might pass).
            break
            ;;
    esac
done

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
# GPU acceleration hints. Chromium gracefully falls back to software paths if
# the GPU/driver doesn't support these features, so they're safe by default.
# Set CLAUDE_DISABLE_GPU_EXTRAS=1 to skip them if you hit buggy driver behavior.
GPU_EXTRAS=""
if [ -z "\$CLAUDE_DISABLE_GPU_EXTRAS" ]; then
    GPU_EXTRAS="--enable-gpu-rasterization --enable-zero-copy --ignore-gpu-blocklist"
fi

ELECTRON_ARGS="\\
    --class=claude-desktop-hardened \\
    --name=claude-desktop-hardened \\
    --ozone-platform-hint=auto \\
    --enable-features=GlobalShortcutsPortal \\
    \$GPU_EXTRAS \\
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
