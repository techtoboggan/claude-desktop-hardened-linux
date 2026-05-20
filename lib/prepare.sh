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
          "('Switch to local: '+localModel+' @ '+(_state.configured&&_state.configured.baseUrl||'')+' (applies to next Code session)\\nRight-click to open the Third-Party Inference setup'):",
          "'No local backend configured yet.\\nClick to open the Third-Party Inference setup (enables conversation mode too)\\nOr: claude-desktop-hardened --model NAME --base-url URL (Code mode only)';",
      "}else{",
        "segL.title='Active: '+localModel+' @ '+_state.baseUrl+'\\nSource: '+(_state.source==='env'?'shell env var':'config file')+'\\nRight-click to re-open setup';",
        "segA.title='Switch to Anthropic (applies to next Code session)';",
      "}",

      // Click handlers — only if action would actually change state.
      // Right-click (or click on \"Local (not set)\") opens the hidden
      // Third-Party Inference setup window baked into Claude Desktop.
      "segA.addEventListener('click',function(e){",
        "e.stopPropagation();",
        "if(_state.mode==='anthropic')return;",
        "console.log('__CDH_BACKEND_SET__anthropic');",
      "});",
      "segL.addEventListener('click',function(e){",
        "e.stopPropagation();",
        "if(!hasLocal){",
          // Not set — open the upstream 3P setup directly.
          "console.log('__CDH_OPEN_3P_SETUP__');",
          "return;",
        "}",
        "if(_state.mode==='local')return;",
        "console.log('__CDH_BACKEND_SET__local');",
      "});",
      // Right-click on either segment opens the 3P setup — lets users
      // re-configure their provider any time without having to undo state.
      "const _open3p=function(e){e.preventDefault();e.stopPropagation();console.log('__CDH_OPEN_3P_SETUP__');};",
      "segA.addEventListener('contextmenu',_open3p);",
      "segL.addEventListener('contextmenu',_open3p);",

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
    // Sub-windows opened by us (e.g. the 3P setup fallback) tag themselves
    // with __cdhSkipInject so we don't paint the title-bar chip/icon into
    // them — those belong to the MAIN claude.ai window only.
    if(w.__cdhSkipInject)return;
    w.webContents.insertCSS(_css).catch(()=>{});
    w.webContents.executeJavaScript(_js).catch(()=>{});
  };

  w.webContents.on("dom-ready",inject);
  w.webContents.on("did-navigate-in-page",inject);

  // Permanent 40px title bar at the top of the window. The asar patch
  // shifts Claude's WebContentsView down by 40px so nothing in the app
  // sits behind the window controls. Skip for our own sub-windows —
  // they use native frame + title, no overlay.
  if(!w.__cdhSkipInject){
    try{w.setTitleBarOverlay({color:"#00000000",symbolColor:"#ffffff",height:_titlebarH});}catch(e){}
  }

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
  // Open Claude Desktop's hidden "Configure Third-Party Inference"
  // setup window. Upstream shipped all the BACKEND infrastructure for
  // this feature (OAuth, MCP integration, protocol handler, window
  // opener) but public builds don't yet include the UI bundle itself
  // (resources/ion-dist/). So we detect:
  //
  //   - If ion-dist/index.html exists → load the real setup UI. The
  //     moment Anthropic ships the bundle in a future update, users
  //     get the feature with zero code changes on our side.
  //   - If it's missing → load a small fallback page that explains
  //     the state and points to what works today (--model / --base-url
  //     for Code mode). Beats an opaque blank window.
  // ===== Third-Party Inference setup window =====
  //
  // Anthropic shipped the BACKEND infrastructure for third-party providers
  // (OAuth, MCP, schema validation in main process) but doesn't include
  // the ion-dist UI bundle in public builds. So we build our own setup
  // UI that writes to claude_desktop_config.json using the schema we
  // reverse-engineered from .vite/build/index.js:
  //
  //   { deploymentMode: "3p" | "1p",
  //     enterpriseConfig: {
  //       inferenceProvider: "gateway" | "bedrock" | "vertex" | "foundry",
  //       inferenceGatewayBaseUrl: "...",
  //       inferenceGatewayApiKey: "...",
  //       inferenceGatewayAuthScheme: "auto" | "x-api-key" | "bearer" | "sso"
  //     } }
  //
  // When deploymentMode === "3p", Claude Desktop sets ANTHROPIC_BASE_URL
  // to the gateway URL, switches CLAUDE_CODE_ENTRYPOINT to
  // "claude-desktop-3p", disables telemetry/feedback/growthbook, and
  // routes BOTH conversation mode AND code mode through the gateway.
  //
  // If Anthropic ever ships ion-dist/ themselves, we auto-defer to their
  // UI instead of ours — same window, different content source.

  let _cdh3pSetupWin=null;

  // Path to the user's claude_desktop_config.json — the source of truth.
  const _cdh3pCfgPath=require("path").join(
    require("electron").app.getPath("userData"),
    "claude_desktop_config.json"
  );

  const _cdh3pReadCfg=()=>{
    try{
      const raw=require("fs").readFileSync(_cdh3pCfgPath,"utf8");
      return JSON.parse(raw);
    }catch(_){return{};}
  };

  const _cdh3pWriteCfg=(cfg)=>{
    const _fsW=require("fs");
    // Back up before overwriting — the user's MCP config and preferences
    // live in this file too, so a bad merge would be very bad.
    try{
      if(_fsW.existsSync(_cdh3pCfgPath)){
        _fsW.copyFileSync(_cdh3pCfgPath,_cdh3pCfgPath+".bak");
      }
    }catch(_){}
    _fsW.mkdirSync(require("path").dirname(_cdh3pCfgPath),{recursive:true});
    _fsW.writeFileSync(_cdh3pCfgPath,JSON.stringify(cfg,null,2),"utf8");
  };

  // ----- Preload script (runs in the setup window's renderer) -----
  // Uses contextBridge so the page can call window.cdh3p.* without
  // contextIsolation surprises.
  const _cdh3pPreloadJs=
    "const{contextBridge,ipcRenderer}=require('electron');\n"+
    "contextBridge.exposeInMainWorld('cdh3p',{\n"+
    "  getConfig:()=>ipcRenderer.invoke('cdh-3p:get-config'),\n"+
    "  saveAndRestart:(cfg)=>ipcRenderer.invoke('cdh-3p:save-restart',cfg),\n"+
    "  disableAndRestart:()=>ipcRenderer.invoke('cdh-3p:disable-restart'),\n"+
    "  testConnection:(p)=>ipcRenderer.invoke('cdh-3p:test',p),\n"+
    "  close:()=>ipcRenderer.invoke('cdh-3p:close'),\n"+
    "});\n";

  // ----- Setup HTML page -----
  // Dark theme matching Claude Desktop's aesthetic. Self-contained:
  // inline CSS + inline script. Talks to main via window.cdh3p (exposed
  // by the preload above).
  const _cdh3pSetupHtml=`<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Configure Third-Party Inference</title>
<style>
  :root{color-scheme:dark;--bg:#1a1a1a;--surface:#222;--surface-2:#2a2a2a;--border:#383838;--text:#e8e8e8;--text-dim:#9c9c9c;--text-faint:#6a6a6a;--accent:#d97757;--accent-dim:rgba(217,119,87,0.18);--ok:#7ee787;--ok-dim:rgba(126,231,135,0.16);--err:#f87171;--err-dim:rgba(248,113,113,0.16);--input:#161616;}
  *{box-sizing:border-box}
  html,body{margin:0;padding:0;background:var(--bg);color:var(--text);font:14px/1.55 system-ui,-apple-system,"Segoe UI",sans-serif;-webkit-font-smoothing:antialiased;height:100vh;overflow:hidden;}
  body{display:flex;flex-direction:column;}
  header{padding:20px 32px 16px;border-bottom:1px solid var(--border);flex-shrink:0;}
  header h1{margin:0;font-size:18px;font-weight:600;letter-spacing:-0.01em;display:flex;align-items:center;gap:10px;}
  header h1::before{content:"";display:inline-block;width:8px;height:8px;border-radius:50%;background:var(--accent);}
  header p{margin:6px 0 0;font-size:13px;color:var(--text-dim);}
  main{flex:1;overflow-y:auto;padding:24px 32px;}
  footer{padding:16px 32px;border-top:1px solid var(--border);background:var(--surface);display:flex;align-items:center;gap:12px;flex-shrink:0;}
  footer .spacer{flex:1}
  .status-banner{margin-bottom:24px;padding:12px 16px;border-radius:8px;display:flex;align-items:center;gap:10px;font-size:13px;}
  .status-banner .dot{width:8px;height:8px;border-radius:50%;flex-shrink:0;}
  .status-banner.anthropic{background:rgba(229,192,123,0.12);color:#e5c07b;}
  .status-banner.anthropic .dot{background:#e5c07b;}
  .status-banner.local{background:var(--ok-dim);color:var(--ok);}
  .status-banner.local .dot{background:var(--ok);}
  h2{margin:0 0 14px;font-size:11px;font-weight:600;color:var(--text-faint);text-transform:uppercase;letter-spacing:0.08em;}
  section{margin-bottom:28px;}
  .provider-card{display:flex;align-items:flex-start;gap:14px;padding:14px 16px;border:1px solid var(--border);border-radius:8px;cursor:pointer;background:var(--surface);transition:border-color .12s,background .12s;margin-bottom:8px;}
  .provider-card:hover{border-color:#4a4a4a;}
  .provider-card.selected{border-color:var(--accent);background:var(--accent-dim);}
  .provider-card.disabled{opacity:0.5;cursor:not-allowed;}
  .provider-card input[type=radio]{margin:2px 0 0;accent-color:var(--accent);flex-shrink:0;}
  .provider-card .pc-body{flex:1;}
  .provider-card .pc-title{font-weight:500;color:var(--text);margin:0 0 2px;}
  .provider-card .pc-desc{font-size:12px;color:var(--text-dim);margin:0;}
  .provider-card .pc-note{font-size:11px;color:var(--text-faint);margin-top:4px;}
  .field{margin-bottom:18px;}
  .field label{display:block;font-size:12px;font-weight:500;color:var(--text-dim);margin-bottom:6px;}
  .field input[type=text],.field input[type=url],.field input[type=password],.field select{width:100%;padding:9px 12px;background:var(--input);color:var(--text);border:1px solid var(--border);border-radius:6px;font:13px/1.4 system-ui,sans-serif;font-family:inherit;}
  .field input:focus,.field select:focus{outline:none;border-color:var(--accent);}
  .field .hint{font-size:11px;color:var(--text-faint);margin-top:5px;}
  .field-row{display:flex;gap:10px;align-items:center;}
  .field-row > input{flex:1;}
  .auth-radios{display:flex;flex-direction:column;gap:6px;}
  .auth-radios label{display:flex;align-items:center;gap:8px;font-size:13px;color:var(--text);cursor:pointer;font-weight:normal;margin:0;}
  .auth-radios input[type=radio]{accent-color:var(--accent);}
  button{font:13px/1 system-ui,sans-serif;font-family:inherit;padding:8px 16px;border-radius:6px;border:1px solid var(--border);background:var(--surface-2);color:var(--text);cursor:pointer;transition:background .12s,border-color .12s;}
  button:hover:not(:disabled){background:#333;border-color:#4a4a4a;}
  button:disabled{opacity:0.5;cursor:not-allowed;}
  button.primary{background:var(--accent);border-color:var(--accent);color:white;font-weight:500;}
  button.primary:hover:not(:disabled){background:#c66a4b;border-color:#c66a4b;}
  button.danger{color:var(--err);}
  button.danger:hover:not(:disabled){background:var(--err-dim);border-color:var(--err);}
  button.ghost{background:transparent;border-color:transparent;color:var(--text-dim);}
  button.ghost:hover:not(:disabled){background:var(--surface-2);color:var(--text);}
  .test-row{display:flex;align-items:center;gap:12px;margin-top:8px;}
  .test-msg{font-size:12px;}
  .test-msg.ok{color:var(--ok);}
  .test-msg.err{color:var(--err);}
  .test-msg.pending{color:var(--text-dim);}
  details{margin-top:12px;font-size:12px;color:var(--text-dim);}
  details summary{cursor:pointer;color:var(--text-faint);padding:6px 0;}
  details pre{background:var(--input);padding:10px 14px;border-radius:5px;overflow:auto;font:11px/1.5 "SF Mono",Monaco,monospace;border:1px solid var(--border);}
  .restart-note{margin-top:18px;padding:12px 16px;background:var(--surface-2);border-left:3px solid var(--accent);border-radius:4px;font-size:12px;color:var(--text-dim);}
  .restart-note strong{color:var(--text);}
</style>
</head>
<body>

<header>
  <h1>Configure Third-Party Inference</h1>
  <p>Route Claude Desktop's conversation and code modes through your own model backend.</p>
</header>

<main>
  <div id="status-banner" class="status-banner anthropic">
    <span class="dot"></span>
    <span id="status-text">Loading current configuration…</span>
  </div>

  <section>
    <h2>Provider</h2>
    <label class="provider-card selected" id="card-gateway">
      <input type="radio" name="provider" value="gateway" checked>
      <div class="pc-body">
        <div class="pc-title">Gateway</div>
        <div class="pc-desc">Anthropic-compatible HTTP endpoint. Works with LiteLLM, LM Studio, Ollama, OpenRouter, vLLM, and any service that speaks the /v1/messages API.</div>
      </div>
    </label>
    <label class="provider-card disabled">
      <input type="radio" name="provider" value="bedrock" disabled>
      <div class="pc-body">
        <div class="pc-title">AWS Bedrock</div>
        <div class="pc-desc">Configure via JSON for now — needs AWS credentials.</div>
        <div class="pc-note">Edit <code>claude_desktop_config.json</code> directly to set up Bedrock.</div>
      </div>
    </label>
    <label class="provider-card disabled">
      <input type="radio" name="provider" value="vertex" disabled>
      <div class="pc-body">
        <div class="pc-title">Google Vertex AI</div>
        <div class="pc-desc">Configure via JSON for now — needs GCP service account.</div>
      </div>
    </label>
    <label class="provider-card disabled">
      <input type="radio" name="provider" value="foundry" disabled>
      <div class="pc-body">
        <div class="pc-title">Azure AI Foundry</div>
        <div class="pc-desc">Configure via JSON for now — needs Azure resource name.</div>
      </div>
    </label>
  </section>

  <section id="gateway-section">
    <h2>Gateway settings</h2>

    <div class="field">
      <label for="baseUrl">Base URL</label>
      <input type="url" id="baseUrl" placeholder="http://localhost:4000" autocomplete="off" spellcheck="false">
      <div class="hint">The Anthropic-compatible endpoint that handles <code>/v1/messages</code>. Examples: <code>http://localhost:4000</code> (LiteLLM), <code>http://localhost:1234/v1</code> (LM Studio), <code>https://openrouter.ai/api/v1</code>.</div>
    </div>

    <div class="field">
      <label for="apiKey">API key</label>
      <input type="password" id="apiKey" placeholder="sk-…" autocomplete="off" spellcheck="false">
      <div class="hint">Sent to the gateway with every request. Stored in <code>~/.config/Claude/claude_desktop_config.json</code> (filesystem-readable but not transmitted anywhere by us).</div>
    </div>

    <div class="field">
      <label>Authentication scheme</label>
      <div class="auth-radios">
        <label><input type="radio" name="authScheme" value="bearer" checked> <strong>Bearer</strong> — <code>Authorization: Bearer …</code> (LiteLLM default)</label>
        <label><input type="radio" name="authScheme" value="x-api-key"> <strong>X-Api-Key</strong> — <code>X-Api-Key: …</code> header</label>
        <label><input type="radio" name="authScheme" value="auto"> <strong>Auto</strong> — try both</label>
      </div>
    </div>

    <div class="field">
      <div class="test-row">
        <button id="btn-test" type="button">Test connection</button>
        <span id="test-msg" class="test-msg"></span>
      </div>
    </div>
  </section>

  <div class="restart-note">
    <strong>Restart required.</strong> <code>deploymentMode</code> is read once at startup, so saving here triggers an app restart. Your current chat state will be lost — finish any unsaved work first.
  </div>

  <details>
    <summary>View the JSON that will be written</summary>
    <pre id="json-preview"></pre>
  </details>
</main>

<footer>
  <button id="btn-disable" class="danger" type="button">Use Anthropic (disable 3P)</button>
  <div class="spacer"></div>
  <button id="btn-cancel" class="ghost" type="button">Cancel</button>
  <button id="btn-save" class="primary" type="button">Save & Restart</button>
</footer>

<script>
(function(){
  const $=id=>document.getElementById(id);
  const api=window.cdh3p;
  if(!api){
    $("status-text").textContent="Setup bridge unavailable — preload script failed to load.";
    return;
  }

  // Build the config object from current form state.
  function readForm(){
    return {
      provider:document.querySelector('input[name=provider]:checked').value,
      baseUrl:$("baseUrl").value.trim(),
      apiKey:$("apiKey").value,
      authScheme:document.querySelector('input[name=authScheme]:checked').value,
    };
  }

  function previewJson(form){
    const out={
      deploymentMode:"3p",
      enterpriseConfig:{
        inferenceProvider:form.provider,
      },
    };
    if(form.provider==="gateway"){
      out.enterpriseConfig.inferenceGatewayBaseUrl=form.baseUrl||"<unset>";
      if(form.apiKey)out.enterpriseConfig.inferenceGatewayApiKey="<redacted>";
      out.enterpriseConfig.inferenceGatewayAuthScheme=form.authScheme;
    }
    return JSON.stringify(out,null,2);
  }

  function updatePreview(){
    $("json-preview").textContent=previewJson(readForm());
  }

  function validate(form){
    if(form.provider!=="gateway")return "Only Gateway is supported via this UI right now.";
    if(!form.baseUrl)return "Base URL is required.";
    if(!/^https?:\\/\\//.test(form.baseUrl))return "Base URL must start with http:// or https://";
    return null;
  }

  function setTestMsg(text,kind){
    const el=$("test-msg");
    el.textContent=text;
    el.className="test-msg "+(kind||"");
  }

  // Wire up listeners
  ["baseUrl","apiKey"].forEach(id=>$(id).addEventListener("input",updatePreview));
  document.querySelectorAll('input[name=provider],input[name=authScheme]').forEach(r=>r.addEventListener("change",updatePreview));

  $("btn-test").addEventListener("click",async()=>{
    const form=readForm();
    const err=validate(form);
    if(err){setTestMsg(err,"err");return;}
    setTestMsg("Probing…","pending");
    $("btn-test").disabled=true;
    try{
      const res=await api.testConnection({baseUrl:form.baseUrl,apiKey:form.apiKey,authScheme:form.authScheme});
      if(res.ok){
        setTestMsg("Reachable — HTTP "+res.status+(res.note?" ("+res.note+")":""),"ok");
      }else{
        setTestMsg(res.error||"Failed","err");
      }
    }catch(e){setTestMsg("Test failed: "+e.message,"err");}
    $("btn-test").disabled=false;
  });

  $("btn-save").addEventListener("click",async()=>{
    const form=readForm();
    const err=validate(form);
    if(err){setTestMsg(err,"err");return;}
    $("btn-save").disabled=true;
    try{
      await api.saveAndRestart(form);
    }catch(e){
      setTestMsg("Save failed: "+e.message,"err");
      $("btn-save").disabled=false;
    }
  });

  $("btn-disable").addEventListener("click",async()=>{
    $("btn-disable").disabled=true;
    try{
      await api.disableAndRestart();
    }catch(e){
      setTestMsg("Disable failed: "+e.message,"err");
      $("btn-disable").disabled=false;
    }
  });

  $("btn-cancel").addEventListener("click",()=>api.close());

  // Load existing config and pre-populate form.
  api.getConfig().then(cfg=>{
    const ec=cfg.enterpriseConfig||{};
    const provider=ec.inferenceProvider||"gateway";
    const radio=document.querySelector('input[name=provider][value="'+provider+'"]');
    if(radio&&!radio.disabled)radio.checked=true;
    if(ec.inferenceGatewayBaseUrl)$("baseUrl").value=ec.inferenceGatewayBaseUrl;
    if(ec.inferenceGatewayApiKey)$("apiKey").value=ec.inferenceGatewayApiKey;
    if(ec.inferenceGatewayAuthScheme){
      const r=document.querySelector('input[name=authScheme][value="'+ec.inferenceGatewayAuthScheme+'"]');
      if(r)r.checked=true;
    }
    const isLocal=cfg.deploymentMode==="3p";
    const banner=$("status-banner");
    if(isLocal&&ec.inferenceGatewayBaseUrl){
      banner.className="status-banner local";
      $("status-text").textContent="Active: "+(ec.inferenceProvider||"gateway")+" → "+ec.inferenceGatewayBaseUrl;
    }else{
      banner.className="status-banner anthropic";
      $("status-text").textContent="Active: Anthropic (default)";
    }
    updatePreview();
  }).catch(e=>{
    $("status-text").textContent="Failed to load config: "+e.message;
  });
})();
</script>

</body>
</html>`;

  const _cdhOpen3pSetup=()=>{
    try{
      if(_cdh3pSetupWin&&!_cdh3pSetupWin.isDestroyed()){
        _cdh3pSetupWin.show();
        _cdh3pSetupWin.focus();
        return;
      }
      const{BrowserWindow:_BW,app:_app,ipcMain:_ipcMain}=require("electron");
      const _pa=require("path");
      const _fsM=require("fs");
      const _os=require("os");

      // Detect if upstream has shipped the ion-dist UI bundle. If they
      // ever do, defer to their UI (so we get any future improvements
      // for free). Otherwise serve our own.
      const _resPath=process.resourcesPath||_pa.dirname(_app.getAppPath());
      const _ionIdx=_pa.join(_resPath,"ion-dist","index.html");
      const _useUpstream=_fsM.existsSync(_ionIdx);

      // Write preload + HTML to temp files (file:// avoids the
      // data: URL CSP restriction on inline styles).
      const _tmpPreload=_pa.join(_os.tmpdir(),"cdh-3p-preload-"+process.pid+".js");
      const _tmpHtml=_pa.join(_os.tmpdir(),"cdh-3p-setup-"+process.pid+".html");
      try{_fsM.writeFileSync(_tmpPreload,_cdh3pPreloadJs,"utf8");}catch(_){}
      try{_fsM.writeFileSync(_tmpHtml,_cdh3pSetupHtml,"utf8");}catch(_){}

      // Register IPC handlers (idempotent — drop existing before re-add).
      const _handlers={
        "cdh-3p:get-config":()=>_cdh3pReadCfg(),
        "cdh-3p:save-restart":(_e,form)=>{
          const cfg=_cdh3pReadCfg();
          cfg.deploymentMode="3p";
          cfg.enterpriseConfig=cfg.enterpriseConfig||{};
          cfg.enterpriseConfig.inferenceProvider=form.provider||"gateway";
          if(form.provider==="gateway"){
            if(form.baseUrl)cfg.enterpriseConfig.inferenceGatewayBaseUrl=form.baseUrl;
            if(form.apiKey)cfg.enterpriseConfig.inferenceGatewayApiKey=form.apiKey;
            if(form.authScheme)cfg.enterpriseConfig.inferenceGatewayAuthScheme=form.authScheme;
          }
          _cdh3pWriteCfg(cfg);
          console.log("[cowork-linux] 3P setup → wrote deploymentMode=3p, restarting app");
          setTimeout(()=>{_app.relaunch();_app.exit(0);},150);
          return{ok:true};
        },
        "cdh-3p:disable-restart":()=>{
          const cfg=_cdh3pReadCfg();
          cfg.deploymentMode="1p";
          delete cfg.enterpriseConfig;
          _cdh3pWriteCfg(cfg);
          console.log("[cowork-linux] 3P setup → reverted to deploymentMode=1p, restarting app");
          setTimeout(()=>{_app.relaunch();_app.exit(0);},150);
          return{ok:true};
        },
        "cdh-3p:test":async(_e,p)=>{
          try{
            const{net:_net}=require("electron");
            const{baseUrl,apiKey,authScheme}=p;
            return await new Promise((resolve)=>{
              const req=_net.request({url:baseUrl,method:"GET"});
              if(apiKey){
                if(authScheme==="x-api-key")req.setHeader("X-Api-Key",apiKey);
                else if(authScheme==="auto"){
                  req.setHeader("Authorization","Bearer "+apiKey);
                  req.setHeader("X-Api-Key",apiKey);
                }else req.setHeader("Authorization","Bearer "+apiKey);
              }
              const _t=setTimeout(()=>{try{req.abort();}catch(_){}resolve({ok:false,error:"Timeout after 5s"});},5000);
              req.on("response",(res)=>{
                clearTimeout(_t);
                let note;
                if(res.statusCode===401||res.statusCode===403)note="auth rejected — check API key";
                else if(res.statusCode===404)note="endpoint reachable, root path 404 (normal)";
                resolve({ok:true,status:res.statusCode,note:note});
              });
              req.on("error",(err)=>{clearTimeout(_t);resolve({ok:false,error:err.message});});
              req.end();
            });
          }catch(ex){return{ok:false,error:ex.message};}
        },
        "cdh-3p:close":()=>{
          if(_cdh3pSetupWin&&!_cdh3pSetupWin.isDestroyed())_cdh3pSetupWin.close();
          return{ok:true};
        },
      };
      for(const ch of Object.keys(_handlers)){
        try{_ipcMain.removeHandler(ch);}catch(_){}
        _ipcMain.handle(ch,_handlers[ch]);
      }

      _cdh3pSetupWin=new _BW({
        width:780,height:760,
        minWidth:680,minHeight:600,
        autoHideMenuBar:true,
        title:"Configure Third-Party Inference",
        backgroundColor:"#1a1a1a",
        webPreferences:{
          preload:_useUpstream?_pa.join(_app.getAppPath(),".vite","build","mainView.js"):_tmpPreload,
          contextIsolation:true,
          nodeIntegration:false,
          sandbox:false,
        },
      });

      // Tag so the title-bar chip injector skips this window.
      _cdh3pSetupWin.__cdhSkipInject=true;

      if(_useUpstream){
        _cdh3pSetupWin.loadURL("netezza://localhost/setup-desktop-3p");
        console.log("[cowork-linux] 3P setup: deferring to upstream ion-dist UI");
      }else{
        _cdh3pSetupWin.loadURL("file://"+_tmpHtml);
        console.log("[cowork-linux] 3P setup: using our own UI at "+_tmpHtml);
      }

      _cdh3pSetupWin.webContents.on("did-fail-load",(e,code,desc,url)=>{
        console.error("[cowork-linux] 3P setup page failed to load:",code,desc,url);
      });
      _cdh3pSetupWin.on("closed",()=>{
        try{_fsM.unlinkSync(_tmpPreload);}catch(_){}
        try{_fsM.unlinkSync(_tmpHtml);}catch(_){}
        _cdh3pSetupWin=null;
      });
    }catch(ex){
      console.error("[cowork-linux] Failed to open 3P setup:",ex.message);
    }
  };

  w.webContents.on("console-message",(...args)=>{
    const msg=(args[0]&&args[0].message)||(args.length>=3?args[2]:"");
    if(msg==="__CDH_BACKEND_SET__anthropic")_cdhSetBackend("anthropic");
    else if(msg==="__CDH_BACKEND_SET__local")_cdhSetBackend("local");
    else if(msg==="__CDH_OPEN_3P_SETUP__")_cdhOpen3pSetup();
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
        --enable-third-party-setup)
            # Flip the hidden \`allowDevTools\` flag in developer_settings.json,
            # which surfaces the upstream "Configure Third-Party Inference…"
            # menu item (Help menu). Our title-bar chip can open the same
            # window directly without this flag, so this is mostly for users
            # who prefer the menu.
            DEV_SETTINGS="\${XDG_CONFIG_HOME:-\$HOME/.config}/Claude/developer_settings.json"
            mkdir -p "\$(dirname "\$DEV_SETTINGS")"
            if command -v python3 >/dev/null 2>&1; then
                python3 -c "
import json, os
p = '\$DEV_SETTINGS'
cfg = {}
if os.path.exists(p):
    try:
        with open(p) as f: cfg = json.load(f) or {}
    except: pass
cfg['allowDevTools'] = True
with open(p, 'w') as f: json.dump(cfg, f, indent=2)
print('Enabled upstream Third-Party Inference menu item.')
print('Restart Claude Desktop to see it in the Help menu.')
print('(You can also click \"Local (not set)\" in the title bar chip — no restart needed.)')"
            else
                echo "Error: python3 required" >&2
                exit 1
            fi
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
