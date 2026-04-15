#!/usr/bin/env node
/**
 * patch-window.js — Patch Claude Desktop window decorations for Linux CSD
 *
 * Usage: node patch-window.js <path-to-extracted-asar-dir>
 *
 * Replaces macOS-specific title bar settings with Electron 28+ Linux CSD:
 *   titleBarStyle:"hidden" + titleBarOverlay:{color:"#00000000",...}
 *
 * This lets Electron draw native close/min/max buttons inside the app's
 * own content area (just like Firefox on Linux), giving a clean merged look.
 */

const fs = require('fs');
const path = require('path');

const asarDir = process.argv[2];
if (!asarDir || !fs.existsSync(asarDir)) {
  console.error('Usage: node patch-window.js <path-to-extracted-asar-dir>');
  process.exit(1);
}

const mainJs = path.join(asarDir, '.vite', 'build', 'index.js');
if (!fs.existsSync(mainJs)) {
  console.error(`Not found: ${mainJs}`);
  process.exit(1);
}

let code = fs.readFileSync(mainJs, 'utf8');
let patchCount = 0;

function patch(name, fn) {
  const result = fn();
  if (result === false) {
    console.log(`  [SKIP] ${name}`);
  } else {
    patchCount++;
    console.log(`  [OK]   ${name}`);
  }
}

console.log('Patching window decorations for Linux CSD...');

// Replace any existing titleBarOverlay value (inline object or variable reference)
// with the transparent overlay that lets app content show behind native buttons.
patch('titleBarOverlay → transparent CSD', () => {
  const before = code.length;
  code = code.replace(
    /titleBarOverlay:(?:\{[^}]*\}|\w+)/g,
    'titleBarOverlay:{color:"#00000000",symbolColor:"#ffffff",height:40}'
  );
  if (code.length === before) return false;
});

// Switch hiddenInset (macOS inset) to hidden (Linux frameless with app-drawn chrome)
patch('titleBarStyle: hiddenInset → hidden', () => {
  if (!code.includes('titleBarStyle:"hiddenInset"')) return false;
  code = code.replace(/titleBarStyle:"hiddenInset"/g, 'titleBarStyle:"hidden"');
});

// Remove trafficLightPosition (macOS-only — causes errors on Linux)
patch('Remove trafficLightPosition', () => {
  if (!code.includes('trafficLightPosition')) return false;
  code = code.replace(/,?trafficLightPosition:\{[^}]*\},?/g, ',');
  code = code.replace(/,,+/g, ',');
});

// Shift Claude's main WebContentsView down by 40px so it sits BELOW the
// titleBarOverlay zone instead of behind it. Upstream already has this as
// a parameterizable offset — `h=0` hardcodes "no inset" for macOS traffic
// lights which are drawn in-content. On Linux with our 40px overlay we
// need to push the view down so 100vh inside the Claude UI equals
// windowHeight - 40 and nothing sits behind the window controls.
//
// This function is called on did-finish-load, show, and resize — so the
// offset applies across the entire lifetime of the window.
patch('Claude view y-offset: 0 → 40 (Linux titlebar inset)', () => {
  const before = code.length;
  code = code.replace(
    /h=0;([a-zA-Z_$][a-zA-Z_0-9$]*)\.setBounds\(\{x:0,y:h,width:p\.width,height:p\.height-h\}\)/g,
    'h=40;$1.setBounds({x:0,y:h,width:p.width,height:p.height-h})'
  );
  if (code.length === before) return false;
});

fs.writeFileSync(mainJs, code);
console.log(`  ${patchCount} window patches applied`);
