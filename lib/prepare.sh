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
// 40px-tall band across the top-right of the window. We can't shrink it
// without losing the buttons, and we can't make it translucent without
// losing the click region — so instead we push the entire web content
// down by 40px so nothing in the Claude UI sits behind the buttons.
//
// CSS injected into every webContents:
//   - html { padding-top: 40px } reserves space at the top
//   - box-sizing keeps the layout calc honest
//   - body, body * no-drag so buttons inside the page stay clickable in
//     the parts of the title bar zone that are draggable
//
// JS sets html background to match body's computed background so the
// empty 40px strip on the LEFT of the title bar doesn't flash white —
// it picks up Claude's dark theme automatically.
const _titlebarH=40;
const _injectedCss=
  // Lock html to exactly viewport height, with the 40px reservation living
  // INSIDE that height via border-box. overflow:hidden keeps any oversized
  // child from forcing a scrollbar on the outer document.
  "html{"+
    "height:100vh !important;"+
    "max-height:100vh !important;"+
    "padding-top:"+_titlebarH+"px !important;"+
    "box-sizing:border-box !important;"+
    "overflow:hidden !important;"+
    "margin:0 !important;"+
  "}"+
  // Body fills html's content area (100vh - 40px). Forcing max-height and
  // overflow:hidden on body stops fixed-height children (e.g. `height:100vh`
  // on a React root) from spilling past the bottom edge.
  "body{"+
    "height:100% !important;"+
    "max-height:100% !important;"+
    "margin:0 !important;"+
    "box-sizing:border-box !important;"+
    "overflow:hidden !important;"+
  "}"+
  // React roots commonly declare height:100vh, which is 40px too tall in
  // our layout and would get clipped at the bottom — hiding the mode/model
  // selector. Cap direct body children to 100% so they fit inside body
  // (icon + drag-edge are appended to documentElement, not body, so they
  // aren't affected by this selector).
  "body>*{"+
    "height:100% !important;"+
    "max-height:100% !important;"+
    "min-height:0 !important;"+
  "}"+
  "body,body *{-webkit-app-region:no-drag !important;}";
const _bgSyncJs="(function(){"+
  "if(window.__cdh_bg_synced)return;"+
  "window.__cdh_bg_synced=true;"+
  "const _sync=function(){try{"+
    "const _b=getComputedStyle(document.body).backgroundColor;"+
    "if(_b&&_b!=='rgba(0, 0, 0, 0)'&&_b!=='transparent'){"+
      "document.documentElement.style.background=_b;"+
    "}"+
  "}catch(_){}};"+
  "_sync();"+
  "setTimeout(_sync,500);"+
  "setTimeout(_sync,2000);"+
  // Re-sync if the theme changes (body class/style mutations).
  "try{new MutationObserver(_sync).observe(document.body,{attributes:true,attributeFilter:['class','style']});}catch(_){}"+
"})();";

// Inject reservation CSS + bg sync into ALL webContents (BrowserWindows
// AND WebContentsViews). The main Claude UI renders in a WebContentsView
// (not the BrowserWindow's own webContents), so browser-window-created
// alone misses it.
if(process.platform==="linux"){
  _capp.on("web-contents-created",(e,wc)=>{
    const _apply=()=>{
      wc.insertCSS(_injectedCss).catch(()=>{});
      wc.executeJavaScript(_bgSyncJs).catch(()=>{});
    };
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
    "#_cld_drag_edge{",
      "position:fixed;top:0;left:40px;right:160px;",
      "height:40px;",
      "z-index:2147483646;",
      "-webkit-app-region:drag !important;",
      "user-select:none;",
    "}",
  ].join("");

  // JS: append icon + drag strip to documentElement. No nav-button hunt
  // anymore — the body-level padding-top means there's no overlap.
  const _js=[
    "(function(){",
      "if(document.getElementById('_cld_icon'))return;",
      "const el=document.createElement('div');",
      "el.id='_cld_icon';",
      "const img=document.createElement('img');",
      "img.src='",_iconDataUrl,"';",
      "img.alt='Claude';",
      "el.appendChild(img);",
      "document.documentElement.appendChild(el);",
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

  // Permanent 40px title bar at the top of the window. Web content is
  // pushed down by 40px (via injected CSS in web-contents-created above)
  // so nothing in the Claude UI shares pixels with the window controls.
  // No hover, no polling — just a static, properly-sized native title bar.
  try{w.setTitleBarOverlay({color:"#00000000",symbolColor:"#ffffff",height:_titlebarH});}catch(e){}
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
